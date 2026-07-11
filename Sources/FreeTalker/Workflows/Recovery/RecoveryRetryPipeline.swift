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
}

extension TranscriptionJobStore: RecoveryRetryStoring {}

struct RecoveryRetryPipeline: Sendable {
    typealias ProcessDictation = @Sendable ([Float], AttemptConfiguration) async throws -> RecoveryDictation

    private let store: any RecoveryRetryStoring
    private let loadSamples: @Sendable (URL) throws -> [Float]
    private let processDictation: ProcessDictation
    private let removeSource: @Sendable (URL) throws -> Void
    private let errorStage: @Sendable (any Error) -> JobStage
    private let didMarkReady: @Sendable () async -> Void

    init(
        store: any RecoveryRetryStoring,
        loadSamples: @escaping @Sendable (URL) throws -> [Float] = Self.loadPCM,
        processDictation: @escaping ProcessDictation,
        removeSource: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        errorStage: @escaping @Sendable (any Error) -> JobStage = { _ in .persisting },
        didMarkReady: @escaping @Sendable () async -> Void = {}
    ) {
        self.store = store
        self.loadSamples = loadSamples
        self.processDictation = processDictation
        self.removeSource = removeSource
        self.errorStage = errorStage
        self.didMarkReady = didMarkReady
    }

    func execute(jobID: UUID, configuration: AttemptConfiguration, cancellation: CancellationToken) async throws {
        guard let job = try await store.job(id: jobID), job.kind == .recovery else {
            throw JobStoreError.jobNotFound
        }
        let attempt = try await store.beginAttempt(jobID: jobID, configuration: configuration)
        do {
            try cancellation.checkCancellation()
            try await store.transition(jobID, from: .processing, to: .processing(stage: .transcribing))
            let samples = try loadSamples(URL(fileURLWithPath: job.source.reference))
            try cancellation.checkCancellation()
            _ = try await processDictation(samples, configuration)
            try cancellation.checkCancellation()
            try await store.finishAttempt(attempt.id, result: .succeeded)
            try await store.transition(jobID, from: .processing, to: .ready)
            await didMarkReady()
            try removeSource(URL(fileURLWithPath: job.source.reference))
        } catch {
            try? await store.finishAttempt(
                attempt.id,
                result: .failed(JobFailure(stage: errorStage(error), message: error.localizedDescription))
            )
            throw error
        }
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
