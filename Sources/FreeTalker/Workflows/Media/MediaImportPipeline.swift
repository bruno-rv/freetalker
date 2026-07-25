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

/// A job's language/model settings, resolved fresh at that job's start (not frozen when the
/// pipeline itself was constructed) — see `MediaImportPipeline.resolveLanguageSettings`.
struct MediaImportLanguageSettings: Sendable, Equatable {
    let language: String?
    let model: String
    let candidateLanguages: [String]
}

struct MediaImportPipeline: Sendable {
    private let store: any MediaImportPipelineStoring
    private let jobsDirectory: URL
    private let decoder: any MediaJobAudioDecoding
    private let transcriber: any TimestampedTranscribing
    private let diarizer: any SpeakerDiarizing
    /// Called once at the START of each job's `execute` — never cached across jobs — so a
    /// Settings change made while an earlier job in the queue was running applies to every job
    /// that hasn't started transcribing yet, instead of being frozen at
    /// `AppCoordinator.launchMediaImportWorkflows`'s one-time pipeline construction. See Codex
    /// finding: media import language/model settings frozen at pipeline creation.
    private let resolveLanguageSettings: @Sendable () async -> MediaImportLanguageSettings

    init(
        store: any MediaImportPipelineStoring,
        jobsDirectory: URL,
        decoder: any MediaJobAudioDecoding,
        transcriber: any TimestampedTranscribing,
        diarizer: any SpeakerDiarizing,
        resolveLanguageSettings: @escaping @Sendable () async -> MediaImportLanguageSettings
    ) {
        self.store = store
        self.jobsDirectory = jobsDirectory
        self.decoder = decoder
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.resolveLanguageSettings = resolveLanguageSettings
    }

    /// Convenience for callers (and tests) that want a fixed, unchanging language/model —
    /// wraps the values in a constant-returning closure so every job still goes through
    /// `resolveLanguageSettings`'s single call path.
    init(
        store: any MediaImportPipelineStoring,
        jobsDirectory: URL,
        decoder: any MediaJobAudioDecoding,
        transcriber: any TimestampedTranscribing,
        diarizer: any SpeakerDiarizing,
        language: String?,
        model: String,
        candidateLanguages: [String] = []
    ) {
        let fixed = MediaImportLanguageSettings(language: language, model: model, candidateLanguages: candidateLanguages)
        self.init(
            store: store, jobsDirectory: jobsDirectory, decoder: decoder, transcriber: transcriber, diarizer: diarizer,
            resolveLanguageSettings: { fixed }
        )
    }

    func localJobRunner(
        executionAuthority: LocalJobExecutionAuthority? = nil,
        didChange: LocalJobRunner.DidChange? = nil
    ) -> LocalJobRunner {
        let changes = MediaPipelineChangePublisher(didChange: didChange)
        return LocalJobRunner(store: store, kind: .mediaImport, executorFinalizesJob: true, didChange: didChange, executionAuthority: executionAuthority) { job, token in
            try await execute(job: job, cancellation: token, changes: changes)
        }
    }

    func execute(job: TranscriptionJob, cancellation: CancellationToken) async throws {
        try await execute(job: job, cancellation: cancellation, changes: nil)
    }

    private func execute(
        job: TranscriptionJob,
        cancellation: CancellationToken,
        changes: MediaPipelineChangePublisher?
    ) async throws {
        guard job.kind == .mediaImport else { throw JobStoreError.jobNotFound }
        guard let owner = cancellation.owner else { throw JobStoreError.leaseLost }
        // Resolved once, right at this job's start, then held immutable for the rest of this
        // job's execution — a Settings change while an earlier queued job is still running must
        // not retroactively change an already-started job's language/model, but MUST apply to
        // this one. See Codex finding: media import language/model settings frozen at pipeline
        // creation.
        let languageSettings = await resolveLanguageSettings()
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
                try ownedDirectory.removeInvalidArtifact("audio.wav", source: URL(fileURLWithPath: job.source.reference))
                completed = []
            }
        }

        if !completed.contains(.decode) {
            if let orphan = try? ownedDirectory.openExisting("audio.wav") {
                let valid = ownedDirectory.isNormalizedWAV(orphan)
                ownedDirectory.close(orphan)
                if valid {
                    try ownedDirectory.revalidateIdentity()
                    try await store.persistDecodedMedia(jobID: job.id, owner: owner, derivedAudioPath: audioURL.path)
                    try await store.updateMediaProgress(jobID: job.id, owner: owner, progress: 0.25)
                    completed.insert(.decode)
                } else {
                    try ownedDirectory.removeInvalidArtifact("audio.wav", source: URL(fileURLWithPath: job.source.reference))
                }
            } else {
                try ownedDirectory.removeInvalidArtifact("audio.wav", source: URL(fileURLWithPath: job.source.reference))
            }
        }

        if !completed.contains(.decode) {
            try cancellation.checkCancellation()
            try await store.advanceMediaStage(jobID: job.id, owner: owner, stage: .decoding)
            await changes?.stage(job.id)
            let temporary = try ownedDirectory.createTemporaryFile()
            defer { ownedDirectory.discard(temporary); ownedDirectory.close(temporary) }
            try await decoder.decode(jobID: job.id, destination: temporary.url, cancellation: cancellation) { value in
                let progress = 0.25 * normalized(value)
                Task {
                    try? await changes?.progress(job.id, value: progress) {
                        try await store.updateMediaProgress(jobID: job.id, owner: owner, progress: progress)
                    }
                    if changes == nil { try? await store.updateMediaProgress(jobID: job.id, owner: owner, progress: progress) }
                }
            }
            try cancellation.checkCancellation()
            guard ownedDirectory.isNormalizedWAV(temporary) else { throw MediaImportError.decodeFailed("Decoded audio is not normalized 16 kHz mono WAV") }
            let promoted = try ownedDirectory.promote(temporary, to: "audio.wav")
            try ownedDirectory.revalidateIdentity()
            try await store.persistDecodedMedia(jobID: job.id, owner: owner, derivedAudioPath: promoted.path)
            try await store.updateMediaProgress(jobID: job.id, owner: owner, progress: 0.25)
            await changes?.progress(job.id, value: 0.25) {}
            completed.insert(.decode)
        }


        let inferenceAudio = try ownedDirectory.openExisting("audio.wav")
        defer { ownedDirectory.close(inferenceAudio) }

        if !completed.contains(.transcribe) {
            try cancellation.checkCancellation()
            try await store.advanceMediaStage(jobID: job.id, owner: owner, stage: .transcribing)
            await changes?.stage(job.id)
            let segments = try await transcriber.transcribeFile(at: inferenceAudio.url, language: languageSettings.language, model: languageSettings.model, candidateLanguages: languageSettings.candidateLanguages)
            try cancellation.checkCancellation()
            try ownedDirectory.revalidateIdentity()
            try await store.persistTranscript(jobID: job.id, owner: owner, segments: segments)
            try await store.updateMediaProgress(jobID: job.id, owner: owner, progress: 0.5)
            await changes?.progress(job.id, value: 0.5) {}
            completed.insert(.transcribe)
        }

        if !completed.contains(.diarize) {
            try cancellation.checkCancellation()
            try await store.advanceMediaStage(jobID: job.id, owner: owner, stage: .diarizing)
            await changes?.stage(job.id)
            let turns = try await diarizer.diarizeFile(at: inferenceAudio.url) { value in
                let progress = 0.5 + 0.25 * normalized(value)
                Task {
                    try? await changes?.progress(job.id, value: progress) {
                        try await store.updateMediaProgress(jobID: job.id, owner: owner, progress: progress)
                    }
                    if changes == nil { try? await store.updateMediaProgress(jobID: job.id, owner: owner, progress: progress) }
                }
            }
            try cancellation.checkCancellation()
            try ownedDirectory.revalidateIdentity()
            try await store.persistSpeakerTurns(jobID: job.id, owner: owner, turns: turns)
            try await store.updateMediaProgress(jobID: job.id, owner: owner, progress: 0.75)
            await changes?.progress(job.id, value: 0.75) {}
        }

        try cancellation.checkCancellation()
        try await store.advanceMediaStage(jobID: job.id, owner: owner, stage: .finalizing)
        await changes?.stage(job.id)
        try await cancellation.beginFinalization()
        try ownedDirectory.revalidateIdentity()
        try await store.finalizeMediaImport(jobID: job.id, owner: owner)
    }
}

private actor MediaPipelineChangePublisher {
    private let didChange: LocalJobRunner.DidChange?
    private var lastPublishedProgress: [UUID: Double] = [:]

    init(didChange: LocalJobRunner.DidChange?) { self.didChange = didChange }

    func stage(_ id: UUID) async { await didChange?(id) }

    func progress(
        _ id: UUID,
        value: Double,
        update: @Sendable () async throws -> Void
    ) async rethrows {
        try await update()
        guard value == 1 || value - lastPublishedProgress[id, default: -1] >= 0.02 else { return }
        lastPublishedProgress[id] = value
        await didChange?(id)
    }
}

private func normalized(_ value: Double) -> Double {
    min(1, max(0, value.isFinite ? value : 0))
}
