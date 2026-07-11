@preconcurrency import AVFoundation
import Foundation

protocol MediaImportPipelineStoring: TranscriptionJobStoring {
    func completedMediaStages(jobID: UUID) async throws -> Set<MediaPipelineStage>
    func isDerivedMediaRegistered(jobID: UUID, path: String) async throws -> Bool
    func advanceMediaStage(jobID: UUID, owner: UUID, stage: JobStage) async throws
    func updateMediaProgress(jobID: UUID, owner: UUID, progress: Double) async throws
    func persistDecodedMedia(jobID: UUID, owner: UUID, derivedAudioPath: String) async throws
    func persistTranscript(jobID: UUID, owner: UUID, segments: [TranscriptSegment]) async throws
    func persistSpeakerTurns(jobID: UUID, owner: UUID, turns: [SpeakerTurn]) async throws
    func finalizeMediaImport(jobID: UUID, owner: UUID) async throws
    func invalidateInvalidDecodedMedia(jobID: UUID, owner: UUID) async throws
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
        guard let owner = cancellation.owner else { throw JobStoreError.leaseLost }
        var completed = try await store.completedMediaStages(jobID: job.id)
        let ownedDirectory = try OwnedJobDirectory(root: jobsDirectory, jobID: job.id, create: true)
        let audioURL = ownedDirectory.directoryURL.appendingPathComponent("audio.wav")

        if completed.contains(.decode) {
            let registered = try await store.isDerivedMediaRegistered(jobID: job.id, path: audioURL.path)
            let existing = try? ownedDirectory.openExisting("audio.wav")
            let valid = existing.map(ownedDirectory.isNormalizedWAV) ?? false
            if let existing { ownedDirectory.close(existing) }
            if !valid || !registered {
                try await store.invalidateInvalidDecodedMedia(jobID: job.id, owner: owner)
                try ownedDirectory.unlinkRegistered(path: audioURL.path, source: URL(fileURLWithPath: job.source.reference), fileManager: .default)
                completed = []
            }
        }

        if !completed.contains(.decode) {
            try cancellation.checkCancellation()
            try await store.advanceMediaStage(jobID: job.id, owner: owner, stage: .decoding)
            let temporary = try ownedDirectory.createTemporaryFile()
            defer { ownedDirectory.discard(temporary); ownedDirectory.close(temporary) }
            try await decoder.decode(jobID: job.id, destination: temporary.url, cancellation: cancellation) { value in
                Task { try? await store.updateMediaProgress(jobID: job.id, owner: owner, progress: 0.25 * normalized(value)) }
            }
            try cancellation.checkCancellation()
            guard ownedDirectory.isNormalizedWAV(temporary) else { throw MediaImportError.decodeFailed("Decoded audio is not normalized 16 kHz mono WAV") }
            let promoted = try ownedDirectory.promote(temporary, to: "audio.wav")
            try ownedDirectory.revalidateIdentity()
            try await store.persistDecodedMedia(jobID: job.id, owner: owner, derivedAudioPath: promoted.path)
            try await store.updateMediaProgress(jobID: job.id, owner: owner, progress: 0.25)
            completed.insert(.decode)
        }


        let inferenceAudio = try ownedDirectory.openExisting("audio.wav")
        defer { ownedDirectory.close(inferenceAudio) }

        if !completed.contains(.transcribe) {
            try cancellation.checkCancellation()
            try await store.advanceMediaStage(jobID: job.id, owner: owner, stage: .transcribing)
            let segments = try await transcriber.transcribeFile(at: inferenceAudio.url, language: language, model: model)
            try cancellation.checkCancellation()
            try ownedDirectory.revalidateIdentity()
            try await store.persistTranscript(jobID: job.id, owner: owner, segments: segments)
            try await store.updateMediaProgress(jobID: job.id, owner: owner, progress: 0.5)
            completed.insert(.transcribe)
        }

        if !completed.contains(.diarize) {
            try cancellation.checkCancellation()
            try await store.advanceMediaStage(jobID: job.id, owner: owner, stage: .diarizing)
            let turns = try await diarizer.diarizeFile(at: inferenceAudio.url) { value in
                Task { try? await store.updateMediaProgress(jobID: job.id, owner: owner, progress: 0.5 + 0.25 * normalized(value)) }
            }
            try cancellation.checkCancellation()
            try ownedDirectory.revalidateIdentity()
            try await store.persistSpeakerTurns(jobID: job.id, owner: owner, turns: turns)
            try await store.updateMediaProgress(jobID: job.id, owner: owner, progress: 0.75)
        }

        try cancellation.checkCancellation()
        try await store.advanceMediaStage(jobID: job.id, owner: owner, stage: .finalizing)
        try await cancellation.beginFinalization()
        try ownedDirectory.revalidateIdentity()
        try await store.finalizeMediaImport(jobID: job.id, owner: owner)
    }
}

private func normalized(_ value: Double) -> Double {
    min(1, max(0, value.isFinite ? value : 0))
}
