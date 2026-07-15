import Foundation

enum RecoveryRetention: Int, CaseIterable, Sendable {
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90
    case never = -1
}

struct PurgeResult: Sendable, Equatable {
    let deletedJobIDs: [UUID]
}

struct RecoveryRetentionService: Sendable {
    private let lexicalDirectory: URL
    private let resolvedDirectory: URL
    private let store: any RecoveryJobStoring
    private let fileRemover: any RecoveryFileRemoving
    private let ledger: (any CaptureLedgerStoring)?
    private let fileSystem: any JournalFileSystem

    init(
        directory: URL,
        store: any RecoveryJobStoring,
        fileRemover: any RecoveryFileRemoving = SystemRecoveryFileRemover(),
        ledger: (any CaptureLedgerStoring)? = nil,
        fileSystem: any JournalFileSystem = LocalJournalFileSystem()
    ) {
        lexicalDirectory = directory.standardizedFileURL
        resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.store = store
        self.fileRemover = fileRemover
        self.ledger = ledger
        self.fileSystem = fileSystem
    }

    func purgeExpired(now: Date, retention: RecoveryRetention) async throws -> PurgeResult {
        var claims = try await store.claimedRecoveries()
        if retention != .never {
            let cutoff = now.addingTimeInterval(-Double(retention.rawValue) * 86_400)
            claims += try await store.claimExpiredRecoveries(cutoff: cutoff, claimedAt: now)
        }
        var deleted: [UUID] = []
        for claim in claims {
            guard let sourceURL = ownedSourceURL(claim.sourceReference, id: claim.id) else {
                try await store.recordPurgeError(
                    id: claim.id,
                    message: "Recovery source is outside the owned directory"
                )
                continue
            }
            do {
                let dispositions = RecoveryImportDispositionStore(
                    directory: lexicalDirectory, fileSystem: fileSystem
                )
                if FileManager.default.fileExists(atPath: sourceURL.path) {
                    let descriptor = try dispositions.descriptor(
                        id: claim.id, source: sourceURL, defaultScope: .capture(claim.id)
                    )
                    try dispositions.record(descriptor)
                    try fileRemover.removeItem(at: sourceURL)
                } else if let descriptor = try dispositions.descriptor(id: claim.id) {
                    try dispositions.record(descriptor)
                }
                if try await store.deleteClaimedRecovery(
                    id: claim.id,
                    expectedSourceReference: claim.sourceReference
                ) {
                    deleted.append(claim.id)
                }
                try await cleanupLedger(id: claim.id)
            } catch {
                try await store.recordPurgeError(id: claim.id, message: String(describing: error))
                throw error
            }
        }
        return PurgeResult(deletedJobIDs: deleted)
    }

    private func cleanupLedger(id: UUID) async throws {
        guard let ledger, let session = try await ledger.session(id: id) else { return }
        if session.state != .cancelling {
            try await ledger.transition(
                id: id, from: session.state, to: .cancelling,
                recoveryJobID: session.recoveryJobID,
                libraryDictationID: session.libraryDictationID,
                assetKind: session.assetKind, failureMessage: session.failureMessage,
                contentHash: session.contentHash
            )
        }
        if session.directory.standardizedFileURL == lexicalDirectory {
            try fileSystem.synchronizeDirectory(lexicalDirectory)
            try await ledger.removeCleanedSession(id: id)
        } else {
            let expected = lexicalDirectory.appendingPathComponent(
                id.uuidString, isDirectory: true
            ).standardizedFileURL
            guard session.directory.standardizedFileURL == expected else {
                throw RecoveryFinalizationError.captureIdentityMismatch
            }
            try await CaptureJournalService(fileSystem: fileSystem, ledger: ledger)
                .resumeCleanup(captureID: id)
        }
    }

    private func ownedSourceURL(_ reference: String, id: UUID) -> URL? {
        let source = URL(fileURLWithPath: reference).standardizedFileURL
        guard source.pathExtension == "wav",
              UUID(uuidString: source.deletingPathExtension().lastPathComponent) != nil else {
            return nil
        }
        let parent = source.deletingLastPathComponent()
        let direct = parent == lexicalDirectory
        let nested = parent.lastPathComponent == id.uuidString
            && source.deletingPathExtension().lastPathComponent == id.uuidString
            && parent.deletingLastPathComponent() == lexicalDirectory
        guard direct || nested else { return nil }
        let resolvedSource = source.resolvingSymlinksInPath()
        let resolvedParent = resolvedSource.deletingLastPathComponent()
        let resolvedDirect = resolvedParent == resolvedDirectory
        let resolvedNested = resolvedParent.lastPathComponent == id.uuidString
            && resolvedSource.deletingPathExtension().lastPathComponent == id.uuidString
            && resolvedParent.deletingLastPathComponent() == resolvedDirectory
        guard resolvedDirect || resolvedNested else { return nil }
        return source
    }
}
