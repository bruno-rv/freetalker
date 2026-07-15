import Foundation

struct RecoveryRegistrationRetrier: Sendable {
    static let delays: [Duration] = [.zero, .milliseconds(250), .seconds(1)]
    let sleep: @Sendable (Duration) async -> Void

    init(sleep: @escaping @Sendable (Duration) async -> Void = { delay in
        guard delay > .zero else { return }
        do { try await Task.sleep(for: delay) } catch { return }
    }) {
        self.sleep = sleep
    }

    func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        var finalError: Error?
        for delay in Self.delays {
            await sleep(delay)
            do {
                try await operation()
                return
            } catch {
                finalError = error
            }
        }
        throw finalError ?? CancellationError()
    }
}

struct LegacyRecoveryImporter: Sendable {
    enum Result: Sendable, Equatable { case imported, duplicate, quarantined, disposed }

    let store: TranscriptionJobStore
    let ledger: any CaptureLedgerStoring
    let ownedDirectory: URL
    let codec: CaptureSegmentCodec
    let retrier: RecoveryRegistrationRetrier
    let beforeRegistrationAttempt: @Sendable () async throws -> Void

    func importAudio(
        _ source: URL,
        preferredID: UUID? = nil,
        forceQuarantine: Bool = false
    ) async throws -> Result {
        let data = try codec.fileSystem.read(source)
        let hash = codec.hash(data)
        let id = preferredID ?? Self.stableID(hash: hash)
        let dispositions = RecoveryImportDispositionStore(
            directory: ownedDirectory, fileSystem: codec.fileSystem
        )
        let scope: RecoveryImportScope = preferredID == nil ? .legacy : .capture(id)
        let descriptor: RecoveryImportDescriptor
        if let existing = try dispositions.descriptor(scope: scope, legacyHash: hash) {
            guard existing.id == id, existing.contentHash == hash else {
                throw CaptureJournalError.hashMismatch(source.path)
            }
            descriptor = existing
        } else {
            descriptor = RecoveryImportDescriptor(
                id: id, scope: scope, contentHash: hash
            )
        }
        try dispositions.registerImport(descriptor)
        if try dispositions.contains(descriptor) { return .disposed }
        let existed = try await store.job(id: id) != nil

        let valid: Bool
        if forceQuarantine {
            valid = false
        } else {
            do {
                _ = try RecoveryRetryPipeline.loadPCM(from: source)
                valid = true
            } catch {
                valid = false
            }
        }
        let message = valid
            ? "Recovered audio is ready to process"
            : "Damaged or unsupported recovery audio was quarantined"
        try await retrier.run {
            try await beforeRegistrationAttempt()
            var job = if let existing = try await store.job(id: id) {
                existing
            } else {
                try await store.createProvisionalRecovery(
                    id: id, source: JobSource(reference: source.path), capturedAt: Self.creationDate(source)
                )
            }
            if !valid { try await ensureQuarantine(id: id, source: source, message: message) }
            let owned = if let session = try await ledger.session(id: id) {
                session.directory.appendingPathComponent("\(id.uuidString).wav")
            } else {
                ownedDirectory.appendingPathComponent("\(id.uuidString).wav")
            }
            if source.standardizedFileURL != owned.standardizedFileURL {
                let ownedParent = owned.deletingLastPathComponent()
                if !codec.fileSystem.exists(ownedParent) {
                    try codec.fileSystem.createDirectory(ownedParent)
                    try codec.fileSystem.synchronizeDirectory(ownedParent.deletingLastPathComponent())
                }
                if codec.fileSystem.exists(owned) {
                    guard try codec.hashFile(owned) == hash else {
                        throw CaptureJournalError.hashMismatch(owned.path)
                    }
                } else {
                    let temporary = owned.deletingLastPathComponent().appendingPathComponent(
                        ".\(id.uuidString).\(UUID().uuidString).import.tmp"
                    )
                    try DurableArtifactWriter(fileSystem: codec.fileSystem).commit(
                        data, temporary: temporary, destination: owned
                    )
                }
                if job.source.reference != owned.path {
                    try await store.updateRecoverySource(
                        id: id, expectedSourceReference: job.source.reference,
                        source: JobSource(reference: owned.path)
                    )
                    job = try await store.job(id: id) ?? job
                }
            }
            if case .processing = job.state {
                try await store.failProvisionalRecovery(
                    id: id, failure: JobFailure(stage: .preparing, message: message)
                )
            }
        }
        if existed { return .duplicate }
        return valid ? .imported : .quarantined
    }

    private func ensureQuarantine(id: UUID, source: URL, message: String) async throws {
        let session: CaptureSession
        if let existing = try await ledger.session(id: id) {
            session = existing
        } else {
            let directory = ownedDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
            try codec.fileSystem.createDirectory(directory)
            try codec.fileSystem.synchronizeDirectory(ownedDirectory)
            session = try await ledger.createCapture(.init(
                id: id, directory: directory,
                capturedAt: Self.creationDate(source), sampleRate: 16_000,
                channelCount: 1, inputDeviceUID: nil, destination: "recovered"
            ))
        }
        if session.state == .capturing {
            try await ledger.transition(
                id: id, from: .capturing, to: .damaged, recoveryJobID: id,
                libraryDictationID: nil, assetKind: .quarantined,
                failureMessage: message, contentHash: nil
            )
        }
    }

    private static func creationDate(_ url: URL) -> Date {
        do { return try url.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date() }
        catch { return Date() }
    }

    static func stableID(hash: String) -> UUID {
        let hex = String(hash.prefix(32)).padding(toLength: 32, withPad: "0", startingAt: 0)
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-"
            + "\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: value)!
    }
}
