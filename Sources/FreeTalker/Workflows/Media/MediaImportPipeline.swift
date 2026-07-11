import Foundation

protocol MediaImportPipelineStoring: TranscriptionJobStoring {
    func completedMediaStages(jobID: UUID) async throws -> Set<MediaPipelineStage>
    func updateMediaProgress(jobID: UUID, progress: Double) async throws
    func persistDecodedMedia(jobID: UUID, derivedAudioPath: String) async throws
    func persistTranscript(jobID: UUID, segments: [TranscriptSegment]) async throws
    func persistSpeakerTurns(jobID: UUID, turns: [SpeakerTurn]) async throws
    func finalizeMediaImport(jobID: UUID) async throws
}

extension TranscriptionJobStore: MediaImportPipelineStoring {}

protocol MediaJobAudioDecoding: Sendable {
    func decode(
        jobID: UUID,
        destination: URL,
        cancellation: CancellationToken,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

extension MediaImportService: MediaJobAudioDecoding {}

struct MediaImportPipeline: Sendable {
    private let store: any MediaImportPipelineStoring
    private let jobsDirectory: URL
    private let decoder: any MediaJobAudioDecoding
    private let transcriber: any TimestampedTranscribing
    private let diarizer: any SpeakerDiarizing
    private let language: String?
    private let model: String

    init(
        store: any MediaImportPipelineStoring,
        jobsDirectory: URL,
        decoder: any MediaJobAudioDecoding,
        transcriber: any TimestampedTranscribing,
        diarizer: any SpeakerDiarizing,
        language: String?,
        model: String
    ) {
        self.store = store
        self.jobsDirectory = jobsDirectory
        self.decoder = decoder
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.language = language
        self.model = model
    }

    func localJobRunner(didChange: LocalJobRunner.DidChange? = nil) -> LocalJobRunner {
        LocalJobRunner(store: store, kind: .mediaImport, executorFinalizesJob: true, didChange: didChange) { job, token in
            try await execute(job: job, cancellation: token)
        }
    }

    func execute(job: TranscriptionJob, cancellation: CancellationToken) async throws {
        guard job.kind == .mediaImport else { throw JobStoreError.jobNotFound }
        var completed = try await store.completedMediaStages(jobID: job.id)
        let audioURL = jobsDirectory
            .appendingPathComponent(job.id.uuidString, isDirectory: true)
            .appendingPathComponent("audio.wav")

        if !completed.contains(.decode) {
            try cancellation.checkCancellation()
            try await store.transition(job.id, from: .processing, to: .processing(stage: .decoding))
            try FileManager.default.createDirectory(at: audioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await decoder.decode(jobID: job.id, destination: audioURL, cancellation: cancellation) { value in
                Task { try? await store.updateMediaProgress(jobID: job.id, progress: 0.25 * normalized(value)) }
            }
            try cancellation.checkCancellation()
            guard FileManager.default.fileExists(atPath: audioURL.path) else { throw MediaImportError.decodeFailed("No decoded audio was produced") }
            try await store.persistDecodedMedia(jobID: job.id, derivedAudioPath: audioURL.path)
            try await store.updateMediaProgress(jobID: job.id, progress: 0.25)
            completed.insert(.decode)
        }

        if !completed.contains(.transcribe) {
            try cancellation.checkCancellation()
            try await store.transition(job.id, from: .processing, to: .processing(stage: .transcribing))
            let segments = try await transcriber.transcribeFile(at: audioURL, language: language, model: model)
            try cancellation.checkCancellation()
            try await store.persistTranscript(jobID: job.id, segments: segments)
            try await store.updateMediaProgress(jobID: job.id, progress: 0.5)
            completed.insert(.transcribe)
        }

        if !completed.contains(.diarize) {
            try cancellation.checkCancellation()
            try await store.transition(job.id, from: .processing, to: .processing(stage: .diarizing))
            let turns = try await diarizer.diarizeFile(at: audioURL) { value in
                Task { try? await store.updateMediaProgress(jobID: job.id, progress: 0.5 + 0.25 * normalized(value)) }
            }
            try cancellation.checkCancellation()
            try await store.persistSpeakerTurns(jobID: job.id, turns: turns)
            try await store.updateMediaProgress(jobID: job.id, progress: 0.75)
        }

        try cancellation.checkCancellation()
        try await store.transition(job.id, from: .processing, to: .processing(stage: .finalizing))
        try await cancellation.beginFinalization()
        try await store.finalizeMediaImport(jobID: job.id)
    }
}

private func normalized(_ value: Double) -> Double {
    min(1, max(0, value.isFinite ? value : 0))
}
