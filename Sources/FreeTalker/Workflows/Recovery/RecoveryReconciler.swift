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
    private let registrationRetrier: RecoveryRegistrationRetrier
    private let beforeRegistrationAttempt: @Sendable () async throws -> Void
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
        },
        beforeRegistrationAttempt: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.directory = directory.standardizedFileURL
        self.store = store
        self.ledger = ledger
        self.fileSystem = fileSystem
        self.libraryDictationID = libraryDictationID
        self.beforeRegistrationAttempt = beforeRegistrationAttempt
        registrationRetrier = RecoveryRegistrationRetrier(sleep: retrySleep)
        importer = LegacyRecoveryImporter(
            store: store, ledger: ledger, ownedDirectory: directory.standardizedFileURL,
            codec: CaptureSegmentCodec(fileSystem: fileSystem),
            retrier: RecoveryRegistrationRetrier(sleep: retrySleep),
            beforeRegistrationAttempt: beforeRegistrationAttempt
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
        let jobs: [TranscriptionJob]
        do {
            try fileSystem.createDirectory(directory)
            _ = try await RecoveryRetentionService(
                directory: directory, store: store, ledger: ledger, fileSystem: fileSystem
            ).purgeExpired(now: Date(), retention: .never)
            rootItems = try fileSystem.contents(directory).sorted { $0.path < $1.path }
            sessions = try await ledger.unfinishedSessions()
            jobs = try await store.jobs()
        } catch {
            report.storeFailure = error.localizedDescription
            return report
        }

        let migration = RecoveryOwnershipMigrator(root: directory, fileSystem: fileSystem)
            .migrate(jobs: jobs, sessions: sessions)
        for issue in migration.issues {
            report.recordFailure(
                issue.source,
                CaptureJournalError.failed(issue.message)
            )
        }
        var ownedPaths = Set(sessions.map { $0.directory.standardizedFileURL.path })
            .union(migration.protectedPaths)
        for session in sessions {
            await reconcileKnownSession(session, report: &report)
            ownedPaths.insert(session.directory.standardizedFileURL.path)
        }

        for item in rootItems {
            do {
                guard fileSystem.exists(item) else { continue }
                if Self.preparationCaptureID(item) != nil {
                    try await reconcilePreparationMarker(item, report: &report)
                } else if Self.isPendingMarker(item) {
                    try await reconcilePendingMarker(item, report: &report)
                } else if Self.directoryCaptureID(item) != nil {
                    if !ownedPaths.contains(item.standardizedFileURL.path) {
                        try await reconcileSessionDirectory(item, report: &report)
                    }
                } else if item.pathExtension.lowercased() == "wav" {
                    if !ownedPaths.contains(item.standardizedFileURL.path) {
                        try await reconcileLooseAudio(item, report: &report)
                    }
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
            if try await cleanupDisposedSession(session) { return }
            if let libraryID = try await libraryDictationID(session.id) {
                try await reconcileLibraryOwnedSession(session, libraryID: libraryID)
                return
            }
            let canonical = session.directory.appendingPathComponent("\(session.id.uuidString).wav")
            let current = try await ledger.session(id: session.id) ?? session
            switch current.state {
            case .capturing:
                if fileSystem.exists(canonical) {
                    try await importCanonical(canonical, id: current.id)
                } else if fileSystem.exists(
                    current.directory.appendingPathComponent("capture-diagnostics.json")
                ) {
                    let diagnostics = try CaptureJournalService(
                        fileSystem: fileSystem, ledger: ledger
                    ).loadSilentDiagnostics(current)
                    guard diagnostics.indicatesSilence else {
                        throw RecoveryReconciliationOperationError(
                            operation: "restore silent capture",
                            underlying: CaptureJournalError.failed(
                                "persisted diagnostics contain microphone signal"
                            )
                        )
                    }
                    try await ledger.transition(
                        id: current.id, from: .capturing, to: .silent,
                        recoveryJobID: nil, libraryDictationID: nil,
                        assetKind: .silent,
                        failureMessage: SilentCapturePresentation.message,
                        contentHash: nil
                    )
                    try await CaptureJournalService(
                        fileSystem: fileSystem, ledger: ledger, recoveryRoot: directory
                    )
                        .resumeSilentCleanup(captureID: current.id)
                } else {
                    let segments = try await ledger.committedSegments(captureID: current.id)
                    if !segments.isEmpty {
                        do {
                            let assembled = try CaptureSegmentCodec(fileSystem: fileSystem)
                                .assemble(segments: segments, canonicalURL: canonical)
                            try await ledger.transition(
                                id: current.id, from: .capturing, to: .staged,
                                recoveryJobID: nil, libraryDictationID: nil,
                                assetKind: .audio, failureMessage: nil,
                                contentHash: assembled.contentHash
                            )
                            try await registerCanonical(canonical, id: current.id)
                        } catch {
                            try await quarantineJournal(
                                current, fallback: segments.first?.url,
                                message: "Interrupted capture segments are damaged: \(error.localizedDescription)"
                            )
                        }
                    } else {
                        let failureMarker = current.directory.appendingPathComponent("capture-failure.marker")
                        if fileSystem.exists(failureMarker) {
                            try await quarantineJournal(
                                current, fallback: failureMarker,
                                message: "Capture journal failed before recoverable audio was committed"
                            )
                        } else {
                            try await quarantineJournal(
                                current, fallback: nil,
                                message: "Interrupted capture has no committed audio"
                            )
                        }
                    }
                }
            case .staged:
                if fileSystem.exists(canonical) {
                    try await registerCanonical(canonical, id: current.id)
                } else {
                    try await quarantineJournal(
                        current, fallback: nil,
                        message: "Staged recovery audio is missing"
                    )
                }
            case .damaged:
                let items = fileSystem.exists(current.directory)
                    ? try fileSystem.contents(current.directory) : []
                let fallback = fileSystem.exists(canonical) ? canonical
                    : items.first(where: { $0.lastPathComponent == "capture-failure.marker" })
                        ?? items.first(where: { CaptureSegmentCodec.ordinal(from: $0) != nil })
                try await quarantineJournal(
                    current, fallback: fallback,
                    message: current.failureMessage ?? "Capture journal is damaged"
                )
            case .cancelling:
                try await CaptureJournalService(fileSystem: fileSystem, ledger: ledger)
                    .resumeCleanup(captureID: current.id)
            case .silent:
                try await CaptureJournalService(
                    fileSystem: fileSystem, ledger: ledger, recoveryRoot: directory
                )
                    .resumeSilentCleanup(captureID: current.id)
            case .processing, .libraryCommitted:
                break
            }
        } catch {
            report.recordFailure(session.directory, error)
        }
    }

    private func cleanupDisposedSession(_ snapshot: CaptureSession) async throws -> Bool {
        let dispositions = RecoveryImportDispositionStore(
            directory: directory, fileSystem: fileSystem
        )
        guard let descriptor = try dispositions.descriptor(id: snapshot.id),
              try dispositions.contains(descriptor) else { return false }
        if let job = try await store.job(id: snapshot.id) {
            let source = URL(fileURLWithPath: job.source.reference).standardizedFileURL
            let direct = directory.appendingPathComponent("\(snapshot.id.uuidString).wav")
                .standardizedFileURL
            let nestedDirectory = directory.appendingPathComponent(
                snapshot.id.uuidString, isDirectory: true
            ).standardizedFileURL
            let nested = nestedDirectory.appendingPathComponent("\(snapshot.id.uuidString).wav")
            guard source == direct || source == nested else {
                throw RecoveryFinalizationError.recoveryJobMismatch
            }
            _ = try await store.deleteCommittedRecovery(
                id: job.id, expectedSourceReference: job.source.reference
            )
        }
        guard let current = try await ledger.session(id: snapshot.id) else { return true }
        if current.state != .cancelling {
            try await ledger.transition(
                id: current.id, from: current.state, to: .cancelling,
                recoveryJobID: current.recoveryJobID,
                libraryDictationID: current.libraryDictationID,
                assetKind: current.assetKind, failureMessage: current.failureMessage,
                contentHash: current.contentHash
            )
        }
        if current.directory.standardizedFileURL == directory {
            let canonical = directory.appendingPathComponent("\(current.id.uuidString).wav")
            if fileSystem.exists(canonical) { try fileSystem.remove(canonical) }
            try fileSystem.synchronizeDirectory(directory)
            try await ledger.removeCleanedSession(id: current.id)
        } else {
            let expected = directory.appendingPathComponent(
                current.id.uuidString, isDirectory: true
            ).standardizedFileURL
            guard current.directory.standardizedFileURL == expected else {
                throw RecoveryFinalizationError.captureIdentityMismatch
            }
            try await CaptureJournalService(fileSystem: fileSystem, ledger: ledger)
                .resumeCleanup(captureID: current.id)
        }
        return true
    }

    private func reconcileLibraryOwnedSession(
        _ snapshot: CaptureSession, libraryID: Int64
    ) async throws {
        guard var current = try await ledger.session(id: snapshot.id) else { return }
        if current.state == .cancelling {
            try await CaptureJournalService(fileSystem: fileSystem, ledger: ledger)
                .resumeCleanup(captureID: current.id)
            return
        }
        if current.state != .libraryCommitted {
            try await ledger.transition(
                id: current.id, from: current.state, to: .libraryCommitted,
                recoveryJobID: current.recoveryJobID, libraryDictationID: libraryID,
                assetKind: current.assetKind, failureMessage: current.failureMessage,
                contentHash: current.contentHash
            )
            guard let persisted = try await ledger.session(id: current.id) else { return }
            current = persisted
        }
        guard current.state == .libraryCommitted,
              current.libraryDictationID == libraryID else {
            throw RecoveryFinalizationError.captureIdentityMismatch
        }
        try await RecoveryCaptureService(
            directory: directory, store: store, ledger: ledger,
            journalFileSystem: fileSystem, libraryDictationID: libraryDictationID
        ).resumeLibraryCommittedCapture(captureID: current.id)
    }

    private func quarantineJournal(
        _ session: CaptureSession, fallback: URL?, message: String
    ) async throws {
        if session.state == .capturing || session.state == .staged {
            try await ledger.transition(
                id: session.id, from: session.state, to: .damaged,
                recoveryJobID: session.recoveryJobID ?? session.id, libraryDictationID: nil,
                assetKind: .quarantined, failureMessage: message,
                contentHash: session.contentHash
            )
        }
        let source = fallback ?? session.directory.appendingPathComponent("capture-failure.marker")
        if !fileSystem.exists(source) {
            let temporary = source.deletingLastPathComponent().appendingPathComponent(
                ".capture-failure.\(UUID().uuidString).tmp"
            )
            try DurableArtifactWriter(fileSystem: fileSystem).commit(
                Data(message.utf8), temporary: temporary, destination: source
            )
        }
        let result: LegacyRecoveryImporter.Result
        if let existing = try await importer.existingOwnedLegacyResult(source, id: session.id) {
            result = existing
        } else {
            result = try await importer.importAudio(
                source, preferredID: session.id, forceQuarantine: true
            )
        }
        if result == .disposed {
            if let job = try await store.job(id: session.id) {
                _ = try await store.deleteCommittedRecovery(
                    id: job.id, expectedSourceReference: job.source.reference
                )
            }
            guard let current = try await ledger.session(id: session.id) else { return }
            if current.state != .cancelling {
                try await ledger.transition(
                    id: current.id, from: current.state, to: .cancelling,
                    recoveryJobID: current.recoveryJobID,
                    libraryDictationID: current.libraryDictationID,
                    assetKind: current.assetKind, failureMessage: current.failureMessage,
                    contentHash: current.contentHash
                )
            }
            try await CaptureJournalService(fileSystem: fileSystem, ledger: ledger)
                .resumeCleanup(captureID: current.id)
        }
    }

    private func reconcilePreparationMarker(
        _ marker: URL, report: inout RecoveryReconciliationReport
    ) async throws {
        guard let id = Self.preparationCaptureID(marker) else { return }
        if try await libraryDictationID(id) != nil {
            try fileSystem.remove(marker)
            try fileSystem.synchronizeDirectory(marker.deletingLastPathComponent())
            return
        }
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
        let source = fileSystem.exists(finalAudio) ? finalAudio : temporaryAudio
        guard fileSystem.exists(source) else {
            throw CaptureJournalError.invalidWAV(finalAudio.path)
        }
        if try await libraryDictationID(captureID) != nil {
            try await cleanupLibraryOwnedLoose(captureID, artifact: finalAudio)
            try fileSystem.remove(marker)
            try fileSystem.synchronizeDirectory(directory)
            return
        }
        report.add(try await importer.importAudio(source, preferredID: captureID))
        try fileSystem.remove(marker)
        try fileSystem.synchronizeDirectory(directory)
    }

    private func reconcileSessionDirectory(
        _ sessionDirectory: URL, report: inout RecoveryReconciliationReport
    ) async throws {
        guard let id = Self.directoryCaptureID(sessionDirectory) else { return }
        if try await libraryDictationID(id) != nil {
            try await cleanupLibraryOwnedLoose(id, artifact: sessionDirectory)
            return
        }
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
            if try await libraryDictationID(id) != nil {
                try await cleanupLibraryOwnedLoose(id, artifact: audio)
                return
            }
            if let existing = try await importer.existingOwnedLegacyResult(audio, id: id) {
                report.add(existing)
            } else {
                report.add(try await importer.importAudio(audio, preferredID: id))
            }
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

    private func cleanupLibraryOwnedLoose(_ id: UUID, artifact: URL) async throws {
        if let job = try await store.job(id: id) {
            _ = try await store.deleteCommittedRecovery(
                id: id, expectedSourceReference: job.source.reference
            )
        }
        if fileSystem.exists(artifact) { try fileSystem.remove(artifact) }
        try fileSystem.synchronizeDirectory(artifact.deletingLastPathComponent())
    }

    private func registerCanonical(_ audio: URL, id: UUID) async throws {
        try await registrationRetrier.run {
            try await self.beforeRegistrationAttempt()
            var job = if let existing = try await self.store.job(id: id) {
                existing
            } else {
                try await self.store.createProvisionalRecovery(
                    id: id, source: JobSource(reference: audio.path), capturedAt: Date()
                )
            }
            if let session = try await self.ledger.session(id: id), session.state == .staged {
                try await self.ledger.transition(
                    id: id, from: .staged, to: .processing, recoveryJobID: job.id,
                    libraryDictationID: nil, assetKind: .audio,
                    failureMessage: session.failureMessage, contentHash: session.contentHash
                )
                job = try await self.store.job(id: id) ?? job
            }
            if case .processing = job.state {
                try await self.store.failProvisionalRecovery(
                    id: id,
                    failure: JobFailure(stage: .preparing, message: "Interrupted recording is ready to retry")
                )
            }
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
                    id: id, from: .capturing, to: .damaged, recoveryJobID: id,
                    libraryDictationID: nil, assetKind: .quarantined,
                    failureMessage: message, contentHash: nil
                )
            } catch { throw RecoveryReconciliationOperationError(operation: "mark ownership damaged", underlying: error) }
        }
        do {
            let result = try await importer.importAudio(
                source, preferredID: id, forceQuarantine: true
            )
            if result == .disposed,
               let current = try await ledger.session(id: session.id) {
                if current.state != .cancelling {
                    try await ledger.transition(
                        id: current.id, from: current.state, to: .cancelling,
                        recoveryJobID: current.recoveryJobID,
                        libraryDictationID: current.libraryDictationID,
                        assetKind: current.assetKind, failureMessage: current.failureMessage,
                        contentHash: current.contentHash
                    )
                }
                try await CaptureJournalService(fileSystem: fileSystem, ledger: ledger)
                    .resumeCleanup(captureID: current.id)
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
        case .disposed: duplicates += 1
        }
    }
}
