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

    init(
        directory: URL,
        store: any RecoveryJobStoring,
        fileRemover: any RecoveryFileRemoving = SystemRecoveryFileRemover()
    ) {
        lexicalDirectory = directory.standardizedFileURL
        resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.store = store
        self.fileRemover = fileRemover
    }

    func purgeExpired(now: Date, retention: RecoveryRetention) async throws -> PurgeResult {
        var claims = try await store.claimedRecoveries()
        if retention != .never {
            let cutoff = now.addingTimeInterval(-Double(retention.rawValue) * 86_400)
            claims += try await store.claimExpiredRecoveries(cutoff: cutoff, claimedAt: now)
        }
        var deleted: [UUID] = []
        for claim in claims {
            guard let sourceURL = ownedSourceURL(claim.sourceReference) else {
                try await store.recordPurgeError(
                    id: claim.id,
                    message: "Recovery source is outside the owned directory"
                )
                continue
            }
            do {
                if FileManager.default.fileExists(atPath: sourceURL.path) {
                    try fileRemover.removeItem(at: sourceURL)
                }
                if try await store.deleteClaimedRecovery(
                    id: claim.id,
                    expectedSourceReference: claim.sourceReference
                ) {
                    deleted.append(claim.id)
                }
            } catch {
                try await store.recordPurgeError(id: claim.id, message: String(describing: error))
                throw error
            }
        }
        return PurgeResult(deletedJobIDs: deleted)
    }

    private func ownedSourceURL(_ reference: String) -> URL? {
        let source = URL(fileURLWithPath: reference).standardizedFileURL
        guard source.deletingLastPathComponent() == lexicalDirectory,
              source.pathExtension == "wav",
              UUID(uuidString: source.deletingPathExtension().lastPathComponent) != nil else { return nil }
        let resolvedSource = source.resolvingSymlinksInPath()
        guard resolvedSource.deletingLastPathComponent() == resolvedDirectory else { return nil }
        return source
    }
}
