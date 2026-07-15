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

    func purgeExpired(now _: Date, retention _: RecoveryRetention) async throws -> PurgeResult {
        let claims = try await store.claimedRecoveries()
        // Recovery audio is never age-expired. A claim is created only by an explicit
        // user Delete action; this method resumes those durable claims after interruption.
        let result = try await purge(claims)
        try await cleanupLibraryCommittedSessions()
        return result
    }

    func purgeClaim(id: UUID) async throws -> PurgeResult {
        let claims = try await store.claimedRecoveries().filter { $0.id == id }
        return try await purge(claims)
    }

    private func purge(_ claims: [RecoveryPurgeClaim]) async throws -> PurgeResult {
        var deleted: [UUID] = []
        for claim in claims {
            let validator = RecoveryOwnedArtifactValidator(
                root: lexicalDirectory, id: claim.id, fileManager: .default
            )
            let claimedSource = URL(fileURLWithPath: claim.sourceReference)
            guard let sourceURL = validator.validArtifact(claimedSource)
                    ?? validator.ownedMissingArtifact(claimedSource) else {
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

    private func cleanupLibraryCommittedSessions() async throws {
        guard let ledger else { return }
        for session in try await ledger.unfinishedSessions()
        where session.state == .libraryCommitted {
            let expected = lexicalDirectory.appendingPathComponent(
                session.id.uuidString, isDirectory: true
            ).standardizedFileURL
            guard session.directory.standardizedFileURL == expected,
                  session.directory.resolvingSymlinksInPath().standardizedFileURL
                    == resolvedDirectory.appendingPathComponent(
                        session.id.uuidString, isDirectory: true
                    ).standardizedFileURL else {
                throw RecoveryFinalizationError.captureIdentityMismatch
            }
            try await CaptureJournalService(fileSystem: fileSystem, ledger: ledger)
                .resumeCleanup(captureID: session.id)
        }
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

}
