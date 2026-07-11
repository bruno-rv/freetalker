import Darwin
import Foundation

struct RecoveryMetadata: Sendable, Equatable {
    let capturedAt: Date
    let failure: JobFailure
}

struct RecoveryCaptureRollbackError: Error {
    let persistenceError: any Error
    let rollbackError: any Error
}

struct RecoveryPurgeClaim: Sendable, Equatable {
    let id: UUID
    let sourceReference: String
    let claimedAt: Date
    let cleanupError: String?
}

protocol RecoveryFileRemoving: Sendable {
    func removeItem(at url: URL) throws
}

struct SystemRecoveryFileRemover: RecoveryFileRemoving {
    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

protocol RecoveryJobStoring: Sendable {
    func createRecovery(source: JobSource, metadata: RecoveryMetadata) async throws -> TranscriptionJob
    func claimExpiredRecoveries(cutoff: Date, claimedAt: Date) async throws -> [RecoveryPurgeClaim]
    func claimedRecoveries() async throws -> [RecoveryPurgeClaim]
    func recordPurgeError(id: UUID, message: String) async throws
    func deleteClaimedRecovery(id: UUID, expectedSourceReference: String) async throws -> Bool
}

extension TranscriptionJobStore: RecoveryJobStoring {}

struct RecoveryCaptureService: Sendable {
    private let directory: URL
    private let store: any RecoveryJobStoring
    private let fileRemover: any RecoveryFileRemoving

    init(
        directory: URL,
        store: any RecoveryJobStoring,
        fileRemover: any RecoveryFileRemoving = SystemRecoveryFileRemover()
    ) {
        self.directory = directory.standardizedFileURL
        self.store = store
        self.fileRemover = fileRemover
    }

    func preserve(samples: [Float], metadata: RecoveryMetadata) async throws -> UUID {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = UUID().uuidString
        let temporaryURL = directory.appendingPathComponent(".\(stem).tmp")
        let finalURL = directory.appendingPathComponent("\(stem).wav")
        do {
            try writeSynchronously(WAVEncoder.encode(samples: samples, sampleRate: 16_000), to: temporaryURL)
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
            do {
                return try await store.createRecovery(source: JobSource(reference: finalURL.path), metadata: metadata).id
            } catch let persistenceError {
                do {
                    try fileRemover.removeItem(at: finalURL)
                } catch let rollbackError {
                    throw RecoveryCaptureRollbackError(
                        persistenceError: persistenceError,
                        rollbackError: rollbackError
                    )
                }
                throw persistenceError
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func writeSynchronously(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }
}
