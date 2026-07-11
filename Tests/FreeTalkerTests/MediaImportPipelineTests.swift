import Foundation
import Testing
@testable import FreeTalker

@Suite struct MediaImportPipelineTests {
    @Test func transcriptCheckpointSurvivesRestartAndSkipsCompletedWork() async throws {
        let fixture = try MediaPipelineFixture()
        let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        try await fixture.store.transition(job.id, from: .queued, to: .processing(stage: .preparing))
        try FileManager.default.createDirectory(at: fixture.jobDirectory(job.id), withIntermediateDirectories: true)
        try Data().write(to: fixture.audioURL(job.id))
        try await fixture.store.persistDecodedMedia(jobID: job.id, derivedAudioPath: fixture.audioURL(job.id).path)
        try await fixture.store.persistTranscript(jobID: job.id, segments: [.init(start: 0, end: 1, text: "hello")])

        let decoder = PipelineDecodeProbe()
        let transcriber = PipelineTranscribeProbe()
        let restartedStore = try TranscriptionJobStore(databaseURL: fixture.databaseURL, clock: SystemJobClock())
        let pipeline = MediaImportPipeline(store: restartedStore, jobsDirectory: fixture.root, decoder: decoder, transcriber: transcriber, diarizer: PipelineDiarizeProbe(), language: nil, model: "model")
        try await pipeline.execute(job: try #require(await fixture.store.job(id: job.id)), cancellation: CancellationToken())

        #expect(await decoder.calls == 0)
        #expect(await transcriber.calls == 0)
        #expect(try await fixture.store.transcriptSegments(jobID: job.id) == [.init(start: 0, end: 1, text: "hello")])
    }

    @Test func progressNeverMovesBackwardAndCancellationBeforeDecodeDoesNoWork() async throws {
        let fixture = try MediaPipelineFixture()
        let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        try await fixture.store.transition(job.id, from: .queued, to: .processing(stage: .preparing))
        try await fixture.store.updateMediaProgress(jobID: job.id, progress: 0.4)
        try await fixture.store.updateMediaProgress(jobID: job.id, progress: 0.1)
        #expect(try await fixture.store.job(id: job.id)?.progress == 0.4)

        let decoder = PipelineDecodeProbe()
        let token = CancellationToken(); token.cancel()
        await #expect(throws: CancellationError.self) {
            try await fixture.pipeline(decoder: decoder).execute(job: try #require(await fixture.store.job(id: job.id)), cancellation: token)
        }
        #expect(await decoder.calls == 0)
        #expect(try await fixture.store.completedMediaStages(jobID: job.id).isEmpty)
    }

    @Test func speakerTurnsRemainRawWhenNamesChange() async throws {
        let fixture = try MediaPipelineFixture()
        let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        try await fixture.store.transition(job.id, from: .queued, to: .processing(stage: .diarizing))
        let raw = [SpeakerTurn(speakerID: "backend-cluster-7", start: 0, end: 2)]
        try await fixture.store.persistSpeakerTurns(jobID: job.id, turns: raw)
        try await fixture.store.replaceSpeakerName(jobID: job.id, speakerID: "backend-cluster-7", name: "Alice")
        #expect(try await fixture.store.speakerTurns(jobID: job.id) == raw)
        #expect(try await fixture.store.speakerNames(jobID: job.id) == ["backend-cluster-7": "Alice"])
    }

    @Test func transcriptTransactionRollsBackWhenAStoredSegmentIsInvalid() async throws {
        let fixture = try MediaPipelineFixture()
        let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        try await fixture.store.transition(job.id, from: .queued, to: .processing(stage: .preparing))
        await #expect(throws: Error.self) {
            try await fixture.store.persistTranscript(jobID: job.id, segments: [
                .init(start: 0, end: 1, text: "kept out"), .init(start: 2, end: 1, text: "invalid")
            ])
        }
        #expect(try await fixture.store.transcriptSegments(jobID: job.id).isEmpty)
        #expect(try await fixture.store.completedMediaStages(jobID: job.id).isEmpty)
    }

    @Test func diarizationFailureLeavesDurableTranscriptAndRetrySkipsTranscription() async throws {
        let fixture = try MediaPipelineFixture()
        let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        let transcriber = PipelineTranscribeProbe(segments: [.init(start: 0, end: 1, text: "hello")])
        let diarizer = PipelineDiarizeProbe(error: PipelineTestError.failed)
        let pipeline = fixture.pipeline(transcriber: transcriber, diarizer: diarizer)
        let runner = pipeline.localJobRunner()
        await runner.enqueue(job.id)
        await runner.waitUntilIdle()

        #expect(try await fixture.store.transcriptSegments(jobID: job.id).map(\.text) == ["hello"])
        #expect(try await fixture.store.job(id: job.id)?.state == .failed(.init(stage: .diarizing, message: "failed")))
        try await fixture.store.queueMediaImportRetry(jobID: job.id)
        let retry = fixture.pipeline(transcriber: transcriber, diarizer: PipelineDiarizeProbe())
        let retryRunner = retry.localJobRunner()
        await retryRunner.enqueue(job.id)
        await retryRunner.waitUntilIdle()
        #expect(await transcriber.calls == 1)
        #expect(try await fixture.store.job(id: job.id)?.state == .ready)
    }

    @Test func deletingImportRemovesOnlyRecordedDerivedFilesAndDatabaseRows() async throws {
        let fixture = try MediaPipelineFixture()
        try Data("source".utf8).write(to: fixture.source)
        let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        try await fixture.store.transition(job.id, from: .queued, to: .processing(stage: .preparing))
        let derived = fixture.audioURL(job.id)
        try FileManager.default.createDirectory(at: derived.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("derived".utf8).write(to: derived)
        try await fixture.store.persistDecodedMedia(jobID: job.id, derivedAudioPath: derived.path)
        // Even corrupt ownership metadata must never authorize deleting the imported source.
        try await fixture.store.persistDecodedMedia(jobID: job.id, derivedAudioPath: fixture.source.path)

        try await fixture.store.deleteMediaImport(jobID: job.id, fileManager: .default)

        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
        #expect(!FileManager.default.fileExists(atPath: derived.path))
        #expect(try await fixture.store.job(id: job.id) == nil)
    }
}

private enum PipelineTestError: Error, LocalizedError { case failed; var errorDescription: String? { "failed" } }

private struct MediaPipelineFixture {
    let root: URL
    let source: URL
    let databaseURL: URL
    let store: TranscriptionJobStore
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        source = root.appendingPathComponent("source.wav")
        databaseURL = root.appendingPathComponent("jobs.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try TranscriptionJobStore(databaseURL: databaseURL, clock: SystemJobClock())
    }
    func jobDirectory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }
    func audioURL(_ id: UUID) -> URL { jobDirectory(id).appendingPathComponent("audio.wav") }
    func pipeline(decoder: PipelineDecodeProbe = .init(), transcriber: PipelineTranscribeProbe = .init(), diarizer: PipelineDiarizeProbe = .init()) -> MediaImportPipeline {
        MediaImportPipeline(store: store, jobsDirectory: root, decoder: decoder, transcriber: transcriber, diarizer: diarizer, language: nil, model: "model")
    }
}

private actor PipelineDecodeProbe: MediaJobAudioDecoding {
    private(set) var calls = 0
    func decode(jobID: UUID, destination: URL, cancellation: CancellationToken, progress: @escaping @Sendable (Double) -> Void) async throws {
        calls += 1; try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true); try Data().write(to: destination); progress(1)
    }
}

private actor PipelineTranscribeProbe: TimestampedTranscribing {
    private(set) var calls = 0
    let segments: [TranscriptSegment]
    init(segments: [TranscriptSegment] = [.init(start: 0, end: 1, text: "text")]) { self.segments = segments }
    func transcribeFile(at url: URL, language: String?, model: String) async throws -> [TranscriptSegment] { calls += 1; return segments }
}

private actor PipelineDiarizeProbe: SpeakerDiarizing {
    let error: Error?
    init(error: Error? = nil) { self.error = error }
    func diarizeFile(at url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeakerTurn] {
        if let error { throw error }; progress(1); return [.init(speakerID: "raw-0", start: 0, end: 1)]
    }
}
