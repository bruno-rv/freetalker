import AVFoundation
import Foundation

struct RecoveryDictation: Sendable, Equatable {
    let language: String
    let template: String
    let transcript: String
    let refined: String
    let engine: String
}

protocol RecoveryRetryStoring: Sendable {
    func job(id: UUID) async throws -> TranscriptionJob?
    func transition(_ id: UUID, from: JobState.Kind, to state: JobState) async throws
    func beginAttempt(jobID: UUID, configuration: AttemptConfiguration) async throws -> JobAttempt
    func finishAttempt(_ id: Int64, result: AttemptResult) async throws
    func latestUnfinishedAttempt(jobID: UUID) async throws -> JobAttempt?
    func completeAttemptAndMarkJobReady(jobID: UUID, attemptID: Int64) async throws
    func recordSourceCleanupError(jobID: UUID, message: String) async throws
    func completeSourceCleanup(jobID: UUID) async throws
    func jobsNeedingSourceCleanup() async throws -> [TranscriptionJob]
}

extension TranscriptionJobStore: RecoveryRetryStoring {}

struct RecoveryRetryPipeline: Sendable {
    typealias ProcessDictation = @Sendable ([Float], AttemptConfiguration) async throws -> RecoveryDictation

    private let directory: URL
    private let store: any RecoveryRetryStoring
    private let loadSamples: @Sendable (URL) throws -> [Float]
    private let processDictation: ProcessDictation
    private let removeSource: @Sendable (URL) throws -> Void
    private let errorStage: @Sendable (any Error) -> JobStage

    init(
        directory: URL,
        store: any RecoveryRetryStoring,
        loadSamples: @escaping @Sendable (URL) throws -> [Float] = Self.loadPCM,
        processDictation: @escaping ProcessDictation,
        removeSource: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        errorStage: @escaping @Sendable (any Error) -> JobStage = { _ in .persisting }
    ) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.store = store
        self.loadSamples = loadSamples
        self.processDictation = processDictation
        self.removeSource = removeSource
        self.errorStage = errorStage
    }

    func execute(jobID: UUID, configuration: AttemptConfiguration?, cancellation: CancellationToken) async throws {
        guard let job = try await store.job(id: jobID), job.kind == .recovery else {
            throw JobStoreError.jobNotFound
        }
        let attempt: JobAttempt
        if let unfinished = try await store.latestUnfinishedAttempt(jobID: jobID) {
            attempt = unfinished
        } else {
            attempt = try await store.beginAttempt(jobID: jobID, configuration: configuration ?? AttemptConfiguration())
        }
        do {
            try cancellation.checkCancellation()
            try await store.transition(jobID, from: .processing, to: .processing(stage: .transcribing))
            let samples = try loadSamples(URL(fileURLWithPath: job.source.reference))
            try cancellation.checkCancellation()
            _ = try await processDictation(samples, attempt.configuration)
            try cancellation.checkCancellation()
            try await cancellation.beginFinalization()
        } catch {
            try? await store.finishAttempt(
                attempt.id,
                result: .failed(JobFailure(stage: errorStage(error), message: error.localizedDescription))
            )
            throw error
        }
        try await store.completeAttemptAndMarkJobReady(jobID: jobID, attemptID: attempt.id)
        await cleanSource(for: job)
    }

    func retryPendingSourceCleanup() async {
        guard let jobs = try? await store.jobsNeedingSourceCleanup() else { return }
        for job in jobs { await cleanSource(for: job) }
    }

    private func cleanSource(for job: TranscriptionJob) async {
        do {
            guard let source = ownedSource(job.source.reference) else {
                throw RecoveryCleanupError.outsideOwnedDirectory
            }
            if FileManager.default.fileExists(atPath: source.path) { try removeSource(source) }
            try await store.completeSourceCleanup(jobID: job.id)
        } catch {
            try? await store.recordSourceCleanupError(jobID: job.id, message: error.localizedDescription)
        }
    }

    private func ownedSource(_ reference: String) -> URL? {
        let source = URL(fileURLWithPath: reference).standardizedFileURL
        guard source.pathExtension == "wav",
              UUID(uuidString: source.deletingPathExtension().lastPathComponent) != nil,
              source.resolvingSymlinksInPath().deletingLastPathComponent() == directory else { return nil }
        return source
    }

    private static func loadPCM(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

private enum RecoveryCleanupError: LocalizedError {
    case outsideOwnedDirectory
    var errorDescription: String? { "Recovery source is outside the owned directory" }
}
