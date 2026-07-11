import Darwin
import Foundation

struct RecoveryMetadata: Sendable, Equatable {
    let capturedAt: Date
    let failure: JobFailure
}

protocol RecoveryJobStoring: Sendable {
    func createRecovery(source: JobSource, metadata: RecoveryMetadata) async throws -> TranscriptionJob
    func recoveryJobs() async throws -> [TranscriptionJob]
    func deleteRecovery(id: UUID, expectedSourceReference: String) async throws -> Bool
}

extension TranscriptionJobStore: RecoveryJobStoring {}

struct RecoveryCaptureService: Sendable {
    private let directory: URL
    private let store: any RecoveryJobStoring

    init(directory: URL, store: any RecoveryJobStoring) {
        self.directory = directory.standardizedFileURL
        self.store = store
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
            } catch {
                try? FileManager.default.removeItem(at: finalURL)
                throw error
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
