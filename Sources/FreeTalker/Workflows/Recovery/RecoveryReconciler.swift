import Foundation

private struct RecoveryReconciliationOperationError: LocalizedError {
    let operation: String
    let underlying: Error
    var errorDescription: String? { "\(operation): \(underlying.localizedDescription)" }
}

actor RecoveryReconciler {
    private let directory: URL
    private let store: TranscriptionJobStore
    private let ledger: any CaptureLedgerStoring
    private let fileSystem: any JournalFileSystem
    private let libraryDictationID: @Sendable (UUID) async throws -> Int64?
    private let importer: LegacyRecoveryImporter
    private var activeReconciliation: Task<RecoveryReconciliationReport, Never>?

    init(
        directory: URL,
        store: TranscriptionJobStore,
        ledger: any CaptureLedgerStoring,
        fileSystem: any JournalFileSystem = LocalJournalFileSystem(),
        libraryDictationID: @escaping @Sendable (UUID) async throws -> Int64?,
        retrySleep: @escaping @Sendable (Duration) async -> Void = { delay in
            guard delay > .zero else { return }
            do { try await Task.sleep(for: delay) } catch { return }
        }
    ) {
        self.directory = directory.standardizedFileURL
        self.store = store
        self.ledger = ledger
        self.fileSystem = fileSystem
        self.libraryDictationID = libraryDictationID
        importer = LegacyRecoveryImporter(
            store: store,
            codec: CaptureSegmentCodec(fileSystem: fileSystem),
            retrier: RecoveryRegistrationRetrier(sleep: retrySleep)
        )
    }

    func reconcile() async -> RecoveryReconciliationReport {
        if let activeReconciliation { return await activeReconciliation.value }
        let task = Task { await performReconciliation() }
        activeReconciliation = task
        let report = await task.value
        activeReconciliation = nil
        return report
    }

    private func performReconciliation() async -> RecoveryReconciliationReport {
        var report = RecoveryReconciliationReport()
        let rootItems: [URL]
        let sessions: [CaptureSession]
        do {
            try fileSystem.createDirectory(directory)
            rootItems = try fileSystem.contents(directory).sorted { $0.path < $1.path }
            sessions = try await ledger.unfinishedSessions()
            _ = try await store.jobs(kind: .recovery)
        } catch {
            report.storeFailure = error.localizedDescription
            return report
        }

        var ownedPaths = Set(sessions.map { $0.directory.standardizedFileURL.path })
        for session in sessions {
            await reconcileKnownSession(session, report: &report)
            ownedPaths.insert(session.directory.standardizedFileURL.path)
        }

        for item in rootItems {
            do {
                if Self.preparationCaptureID(item) != nil {
                    try await reconcilePreparationMarker(item, report: &report)
                } else if Self.isPendingMarker(item) {
                    try await reconcilePendingMarker(item, report: &report)
                } else if Self.directoryCaptureID(item) != nil {
                    if !ownedPaths.contains(item.standardizedFileURL.path) {
                        try await reconcileSessionDirectory(item, report: &report)
                    }
                } else if item.pathExtension.lowercased() == "wav" {
                    try await reconcileLooseAudio(item, report: &report)
                }
            } catch {
                report.recordFailure(item, error)
            }
        }
        return report
    }

    private func reconcileKnownSession(
        _ session: CaptureSession, report: inout RecoveryReconciliationReport
    ) async {
        do {
            let canonical = session.directory.appendingPathComponent("\(session.id.uuidString).wav")
            if (session.state == .capturing || session.state == .staged),
               fileSystem.exists(canonical) {
                try await importCanonical(canonical, id: session.id)
            }
            if let libraryID = try await libraryDictationID(session.id) {
                if session.state == .processing {
                    try await ledger.transition(
                        id: session.id, from: .processing, to: .libraryCommitted,
                        recoveryJobID: session.recoveryJobID, libraryDictationID: libraryID,
                        assetKind: session.assetKind, failureMessage: session.failureMessage,
                        contentHash: session.contentHash
                    )
                }
                if let current = try await ledger.session(id: session.id),
                   current.state == .libraryCommitted {
                    try await RecoveryCaptureService(
                        directory: directory, store: store, ledger: ledger,
                        journalFileSystem: fileSystem, libraryDictationID: libraryDictationID
                    ).resumeLibraryCommittedCapture(captureID: session.id)
                }
            }
        } catch {
            report.recordFailure(session.directory, error)
        }
    }

    private func reconcilePreparationMarker(
        _ marker: URL, report: inout RecoveryReconciliationReport
    ) async throws {
        guard let id = Self.preparationCaptureID(marker) else { return }
        let existed = try await ledger.session(id: id) != nil
        let captureDirectory = directory.appendingPathComponent(id.uuidString)
        try await createDamagedOwnership(
            id: id, directory: captureDirectory, source: marker,
            message: "Capture preparation was interrupted"
        )
        if existed { report.duplicates += 1 } else { report.quarantined += 1 }
    }

    private func reconcilePendingMarker(
        _ marker: URL, report: inout RecoveryReconciliationReport
    ) async throws {
        let stem = marker.deletingPathExtension().lastPathComponent
        guard let captureID = UUID(uuidString: stem) else { return }
        let finalAudio = directory.appendingPathComponent("\(stem).wav")
        let temporaryAudio = directory.appendingPathComponent(".\(stem).tmp")
        if !fileSystem.exists(finalAudio), fileSystem.exists(temporaryAudio) {
            try fileSystem.rename(temporaryAudio, to: finalAudio)
            try fileSystem.synchronizeDirectory(directory)
        }
        guard fileSystem.exists(finalAudio) else {
            throw CaptureJournalError.invalidWAV(finalAudio.path)
        }
        report.add(try await importer.importAudio(finalAudio, preferredID: captureID))
        try fileSystem.remove(marker)
        try fileSystem.synchronizeDirectory(directory)
    }

    private func reconcileSessionDirectory(
        _ sessionDirectory: URL, report: inout RecoveryReconciliationReport
    ) async throws {
        guard let id = Self.directoryCaptureID(sessionDirectory) else { return }
        let items = try fileSystem.contents(sessionDirectory).sorted { $0.path < $1.path }
        let canonical = sessionDirectory.appendingPathComponent("\(id.uuidString).wav")
        if fileSystem.exists(canonical) {
            try await importCanonical(canonical, id: id)
            report.imported += 1
            return
        }
        let segments = items.filter { CaptureSegmentCodec.ordinal(from: $0) != nil }
        if !segments.isEmpty {
            let request = Self.request(id: id, directory: sessionDirectory)
            _ = try await ledger.createCapture(request)
            let codec = CaptureSegmentCodec(fileSystem: fileSystem)
            var records: [CaptureSegment] = []
            for url in segments {
                guard let ordinal = CaptureSegmentCodec.ordinal(from: url) else { continue }
                let samples = try codec.decode(url)
                let record = CaptureSegment(
                    captureID: id, ordinal: ordinal, url: url,
                    sampleCount: samples.count, contentHash: try codec.hashFile(url)
                )
                try await ledger.recordCommittedSegment(record)
                records.append(record)
            }
            let assembled = try codec.assemble(segments: records.sorted { $0.ordinal < $1.ordinal }, canonicalURL: canonical)
            try await ledger.transition(
                id: id, from: .capturing, to: .staged, recoveryJobID: nil,
                libraryDictationID: nil, assetKind: .audio, failureMessage: nil,
                contentHash: assembled.contentHash
            )
            try await registerCanonical(canonical, id: id)
            report.imported += 1
            return
        }
        if let failureMarker = items.first(where: { $0.lastPathComponent == "capture-failure.marker" }) {
            try await createDamagedOwnership(
                id: id, directory: sessionDirectory, source: failureMarker,
                message: "Capture journal failed before recoverable audio was committed"
            )
            report.quarantined += 1
        }
    }

    private func reconcileLooseAudio(
        _ audio: URL, report: inout RecoveryReconciliationReport
    ) async throws {
        let stem = audio.deletingPathExtension().lastPathComponent
        if let id = UUID(uuidString: stem) {
            report.add(try await importer.importAudio(audio, preferredID: id))
        } else if stem.hasPrefix("failed-") {
            report.add(try await importer.importAudio(audio))
        }
    }

    private func importCanonical(_ audio: URL, id: UUID) async throws {
        let codec = CaptureSegmentCodec(fileSystem: fileSystem)
        _ = try codec.decode(audio)
        let request = Self.request(id: id, directory: audio.deletingLastPathComponent())
        let current: CaptureSession
        do {
            current = if let existing = try await ledger.session(id: id) {
                existing
            } else {
                try await ledger.createCapture(request)
            }
        }
        catch { throw RecoveryReconciliationOperationError(operation: "create capture ownership", underlying: error) }
        if current.state == .capturing {
            do {
                try await ledger.transition(
                    id: id, from: .capturing, to: .staged, recoveryJobID: nil,
                    libraryDictationID: nil, assetKind: .audio, failureMessage: nil,
                    contentHash: try codec.hashFile(audio)
                )
            } catch { throw RecoveryReconciliationOperationError(operation: "stage orphan audio", underlying: error) }
        }
        do { try await registerCanonical(audio, id: id) }
        catch { throw RecoveryReconciliationOperationError(operation: "register orphan recovery", underlying: error) }
    }

    private func registerCanonical(_ audio: URL, id: UUID) async throws {
        let job = if let existing = try await store.job(id: id) {
            existing
        } else {
            try await store.createProvisionalRecovery(
                id: id, source: JobSource(reference: audio.path), capturedAt: Date()
            )
        }
        if let session = try await ledger.session(id: id), session.state == .staged {
            try await ledger.transition(
                id: id, from: .staged, to: .processing, recoveryJobID: job.id,
                libraryDictationID: nil, assetKind: .audio,
                failureMessage: session.failureMessage, contentHash: session.contentHash
            )
        }
        if case .processing = job.state {
            try await store.failProvisionalRecovery(
                id: id,
                failure: JobFailure(stage: .preparing, message: "Interrupted recording is ready to retry")
            )
        }
    }

    private func createDamagedOwnership(
        id: UUID, directory: URL, source: URL, message: String
    ) async throws {
        let session: CaptureSession
        do {
            session = if let existing = try await ledger.session(id: id) {
                existing
            } else {
                try await ledger.createCapture(Self.request(id: id, directory: directory))
            }
        }
        catch { throw RecoveryReconciliationOperationError(operation: "create damaged ownership", underlying: error) }
        if session.state == .capturing {
            do {
                try await ledger.transition(
                    id: id, from: .capturing, to: .damaged, recoveryJobID: nil,
                    libraryDictationID: nil, assetKind: .quarantined,
                    failureMessage: message, contentHash: nil
                )
            } catch { throw RecoveryReconciliationOperationError(operation: "mark ownership damaged", underlying: error) }
        }
        do {
            let job = if let existing = try await store.job(id: id) {
                existing
            } else {
                try await store.createProvisionalRecovery(
                    id: id, source: JobSource(reference: source.path), capturedAt: Date()
                )
            }
            if case .processing = job.state {
                try await store.failProvisionalRecovery(
                    id: id, failure: JobFailure(stage: .preparing, message: message)
                )
            }
        } catch { throw RecoveryReconciliationOperationError(operation: "register damaged recovery", underlying: error) }
    }

    private static func request(id: UUID, directory: URL) -> CaptureStartRequest {
        CaptureStartRequest(
            id: id, directory: directory, capturedAt: Date(),
            sampleRate: Double(CaptureSegmentCodec.sampleRate),
            channelCount: CaptureSegmentCodec.channelCount,
            inputDeviceUID: nil, destination: "recovered"
        )
    }

    private static func directoryCaptureID(_ url: URL) -> UUID? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    private static func preparationCaptureID(_ url: URL) -> UUID? {
        let name = url.lastPathComponent
        let prefix = ".capture-preparation-"
        let suffix = ".marker"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count)))
    }

    private static func isPendingMarker(_ url: URL) -> Bool {
        url.pathExtension == "pending"
            && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
    }
}

private extension RecoveryReconciliationReport {
    mutating func add(_ result: LegacyRecoveryImporter.Result) {
        switch result {
        case .imported: imported += 1
        case .duplicate: duplicates += 1
        case .quarantined: quarantined += 1
        }
    }
}
