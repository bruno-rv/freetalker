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
    private let directory: URL
    private let store: any RecoveryJobStoring

    init(directory: URL, store: any RecoveryJobStoring) {
        self.directory = directory.standardizedFileURL
        self.store = store
    }

    func purgeExpired(now: Date, retention: RecoveryRetention) async throws -> PurgeResult {
        guard retention != .never else { return PurgeResult(deletedJobIDs: []) }
        let cutoff = now.addingTimeInterval(-Double(retention.rawValue) * 86_400)
        let candidates = try await store.recoveryJobs().filter {
            $0.kind == .recovery && $0.state.kind == .failed && $0.createdAt <= cutoff
        }
        var deleted: [UUID] = []
        for job in candidates {
            guard let sourceURL = ownedSourceURL(job.source.reference) else { continue }
            let stagedURL = directory.appendingPathComponent(".purge-\(UUID().uuidString).tmp")
            let exists = FileManager.default.fileExists(atPath: sourceURL.path)
            if exists { try FileManager.default.moveItem(at: sourceURL, to: stagedURL) }
            do {
                if try await store.deleteRecovery(id: job.id, expectedSourceReference: job.source.reference) {
                    if exists { try FileManager.default.removeItem(at: stagedURL) }
                    deleted.append(job.id)
                } else if exists {
                    try FileManager.default.moveItem(at: stagedURL, to: sourceURL)
                }
            } catch {
                if exists { try? FileManager.default.moveItem(at: stagedURL, to: sourceURL) }
                throw error
            }
        }
        return PurgeResult(deletedJobIDs: deleted)
    }

    private func ownedSourceURL(_ reference: String) -> URL? {
        let source = URL(fileURLWithPath: reference).standardizedFileURL
        guard source.deletingLastPathComponent() == directory,
              source.pathExtension == "wav",
              UUID(uuidString: source.deletingPathExtension().lastPathComponent) != nil else { return nil }
        return source
    }
}
