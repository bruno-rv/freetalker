@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import FreeTalker

@Suite struct MediaImportPipelineTests {
    @Test func activeLeaseIsNotStolenByAnotherRunner() async throws {
        let fixture = try MediaPipelineFixture()
        let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        let gate = LeaseExecutionGate()
        let first = LocalJobRunner(store: fixture.store, kind: .mediaImport, leaseDuration: 30, executor: gate.execute)
        let second = LocalJobRunner(store: fixture.store, kind: .mediaImport, leaseDuration: 30, executor: gate.execute)
        await first.enqueue(job.id)
        await gate.waitUntilStarted()
        await second.resumeQueuedJobs()
        await second.waitUntilIdle()
        #expect(await gate.starts == 1)
        await gate.release()
        await first.waitUntilIdle()
    }

    @Test func staleLeaseIsReclaimedAndOldOwnerIsFenced() async throws {
        let clock = MutableJobClock(Date(timeIntervalSince1970: 100))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try TranscriptionJobStore(databaseURL: root.appendingPathComponent("jobs.sqlite"), clock: clock)
        let job = try await store.create(kind: .mediaImport, source: .init(reference: "/source.wav"), now: clock.now)
        let oldOwner = UUID(); _ = try await store.claimQueuedJob(job.id, kind: .mediaImport, owner: oldOwner, leaseDuration: 5)
        clock.advance(by: 6)
        #expect(try await store.recoverStaleJobs(kind: .mediaImport) == 1)
        let newOwner = UUID(); _ = try await store.claimQueuedJob(job.id, kind: .mediaImport, owner: newOwner, leaseDuration: 5)
        await #expect(throws: JobStoreError.leaseLost) { try await store.updateMediaProgress(jobID: job.id, owner: oldOwner, progress: 0.9) }
        try await store.updateMediaProgress(jobID: job.id, owner: newOwner, progress: 0.2)
        #expect(try await store.job(id: job.id)?.progress == 0.2)
    }

    @Test(arguments: ["missing", "corrupt"])
    func invalidDecodedCheckpointIsInvalidatedAndRedecoded(_ condition: String) async throws {
        let fixture = try MediaPipelineFixture()
        let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        let owner = try await fixture.claim(job.id)
        try FileManager.default.createDirectory(at: fixture.jobDirectory(job.id), withIntermediateDirectories: true)
        try writeValidWAV(to: fixture.audioURL(job.id))
        try await fixture.store.persistDecodedMedia(jobID: job.id, owner: owner, derivedAudioPath: fixture.audioURL(job.id).path)
        try await fixture.store.persistTranscript(jobID: job.id, owner: owner, segments: [.init(start: 0, end: 1, text: "stale")])
        if condition == "missing" { try FileManager.default.removeItem(at: fixture.audioURL(job.id)) }
        else { try Data("not wav".utf8).write(to: fixture.audioURL(job.id)) }
        let decoder = PipelineDecodeProbe(); let token = CancellationToken(); token.installLeaseOwner(owner)
        try await fixture.pipeline(decoder: decoder).execute(job: try #require(await fixture.store.job(id: job.id)), cancellation: token)
        #expect(await decoder.calls == 1)
        #expect(try await fixture.store.transcriptSegments(jobID: job.id).map(\.text) == ["text"])
    }
    @Test func transcriptCheckpointSurvivesRestartAndSkipsCompletedWork() async throws {
        let fixture = try MediaPipelineFixture()
        let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        let owner = try await fixture.claim(job.id)
        try FileManager.default.createDirectory(at: fixture.jobDirectory(job.id), withIntermediateDirectories: true)
        try writeValidWAV(to: fixture.audioURL(job.id))
        try await fixture.store.persistDecodedMedia(jobID: job.id, owner: owner, derivedAudioPath: fixture.audioURL(job.id).path)
        try await fixture.store.persistTranscript(jobID: job.id, owner: owner, segments: [.init(start: 0, end: 1, text: "hello")])

        let decoder = PipelineDecodeProbe()
        let transcriber = PipelineTranscribeProbe()
        let restartedStore = try TranscriptionJobStore(databaseURL: fixture.databaseURL, clock: SystemJobClock())
        let pipeline = MediaImportPipeline(store: restartedStore, jobsDirectory: fixture.root, decoder: decoder, transcriber: transcriber, diarizer: PipelineDiarizeProbe(), language: nil, model: "model")
        let token = CancellationToken(); token.installLeaseOwner(owner)
        try await pipeline.execute(job: try #require(await fixture.store.job(id: job.id)), cancellation: token)

        #expect(await decoder.calls == 0)
        #expect(await transcriber.calls == 0)
        #expect(try await fixture.store.transcriptSegments(jobID: job.id) == [.init(start: 0, end: 1, text: "hello")])
    }

    @Test func progressNeverMovesBackwardAndCancellationBeforeDecodeDoesNoWork() async throws {
        let fixture = try MediaPipelineFixture()
        let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        let owner = try await fixture.claim(job.id)
        try await fixture.store.updateMediaProgress(jobID: job.id, owner: owner, progress: 0.4)
        try await fixture.store.updateMediaProgress(jobID: job.id, owner: owner, progress: 0.1)
        #expect(try await fixture.store.job(id: job.id)?.progress == 0.4)

        let decoder = PipelineDecodeProbe()
        let token = CancellationToken(); token.installLeaseOwner(owner); token.cancel()
        await #expect(throws: CancellationError.self) {
            try await fixture.pipeline(decoder: decoder).execute(job: try #require(await fixture.store.job(id: job.id)), cancellation: token)
        }
        #expect(await decoder.calls == 0)
        #expect(try await fixture.store.completedMediaStages(jobID: job.id).isEmpty)
    }

    @Test func speakerTurnsRemainRawWhenNamesChange() async throws {
        let fixture = try MediaPipelineFixture()
        let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        let owner = try await fixture.claim(job.id)
        let raw = [SpeakerTurn(speakerID: "backend-cluster-7", start: 0, end: 2)]
        try await fixture.store.persistSpeakerTurns(jobID: job.id, owner: owner, turns: raw)
        try await fixture.store.replaceSpeakerName(jobID: job.id, speakerID: "backend-cluster-7", name: "Alice")
        #expect(try await fixture.store.speakerTurns(jobID: job.id) == raw)
        #expect(try await fixture.store.speakerNames(jobID: job.id) == ["backend-cluster-7": "Alice"])
    }

    @Test func transcriptTransactionRollsBackWhenAStoredSegmentIsInvalid() async throws {
        let fixture = try MediaPipelineFixture()
        let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        let owner = try await fixture.claim(job.id)
        await #expect(throws: Error.self) {
            try await fixture.store.persistTranscript(jobID: job.id, owner: owner, segments: [
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
        let owner = try await fixture.claim(job.id)
        let derived = fixture.audioURL(job.id)
        try FileManager.default.createDirectory(at: derived.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("derived".utf8).write(to: derived)
        try await fixture.store.persistDecodedMedia(jobID: job.id, owner: owner, derivedAudioPath: derived.path)
        // Even corrupt ownership metadata must never authorize deleting the imported source.
        let alternateSourceSpelling = fixture.root.appendingPathComponent("unused/../source").appendingPathExtension("wav").path
        try await fixture.store.persistDecodedMedia(jobID: job.id, owner: owner, derivedAudioPath: alternateSourceSpelling)
        try await fixture.store.transitionOwned(job.id, owner: owner, to: .ready)

        await #expect(throws: Error.self) {
            try await fixture.store.deleteMediaImport(jobID: job.id, jobsDirectory: fixture.root, fileManager: .default)
        }

        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
        #expect(FileManager.default.fileExists(atPath: derived.path))
        #expect(try await fixture.store.job(id: job.id) != nil)
    }

    @Test func deletionRejectsOutsideTraversalPrefixCollisionSymlinkAndSourceAliases() async throws {
        let fixture = try MediaPipelineFixture()
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("outside".utf8).write(to: outside)
        for index in 0..<4 {
            let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
            let owned = fixture.jobDirectory(job.id); try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
            let registered: URL
            switch index {
            case 0: registered = outside
            case 1: registered = URL(fileURLWithPath: owned.path + "/../" + outside.lastPathComponent)
            case 2:
                registered = fixture.root.appendingPathComponent(job.id.uuidString + "-other").appendingPathComponent("audio.wav")
                try FileManager.default.createDirectory(at: registered.deletingLastPathComponent(), withIntermediateDirectories: true); try Data().write(to: registered)
            default:
                let link = owned.appendingPathComponent("linked.wav"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside); registered = link
            }
            let owner = try await fixture.claim(job.id)
            try await fixture.store.persistDecodedMedia(jobID: job.id, owner: owner, derivedAudioPath: registered.path)
            try await fixture.store.transitionOwned(job.id, owner: owner, to: .ready)
            await #expect(throws: Error.self) { try await fixture.store.deleteMediaImport(jobID: job.id, jobsDirectory: fixture.root) }
            #expect(try await fixture.store.job(id: job.id) != nil)
        }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func deletionRejectsAlternateSourceSpellingAndHardLink() async throws {
        let fixture = try MediaPipelineFixture()
        let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.jobDirectory(UUID()).path), now: .now)
        // Use a second job whose source lives inside its own derived directory to exercise alias identity.
        let source = fixture.jobDirectory(job.id).appendingPathComponent("source.wav")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true); try Data("source".utf8).write(to: source)
        let aliasJob = try await fixture.store.create(kind: .mediaImport, source: .init(reference: source.path), now: .now)
        let aliasRoot = fixture.jobDirectory(aliasJob.id); try FileManager.default.createDirectory(at: aliasRoot.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let hardLink = aliasRoot.appendingPathComponent("hard.wav")
        try FileManager.default.linkItem(at: source, to: hardLink)
        let owner = try await fixture.claim(aliasJob.id)
        try await fixture.store.persistDecodedMedia(jobID: aliasJob.id, owner: owner, derivedAudioPath: hardLink.path)
        try await fixture.store.transitionOwned(aliasJob.id, owner: owner, to: .ready)
        await #expect(throws: Error.self) { try await fixture.store.deleteMediaImport(jobID: aliasJob.id, jobsDirectory: fixture.root) }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: hardLink.path))
    }

    @Test func deletionRequiresTerminalUnleasedJob() async throws {
        let fixture = try MediaPipelineFixture()
        let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        _ = try await fixture.claim(job.id)
        await #expect(throws: JobStoreError.invalidTransition) { try await fixture.store.deleteMediaImport(jobID: job.id, jobsDirectory: fixture.root) }
        #expect(try await fixture.store.job(id: job.id) != nil)
    }

    @Test func deletionRemovesRegisteredOwnedFileAndRowsButNotSource() async throws {
        let fixture = try MediaPipelineFixture(); try Data("source".utf8).write(to: fixture.source)
        let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        let derived = fixture.audioURL(job.id); try FileManager.default.createDirectory(at: derived.deletingLastPathComponent(), withIntermediateDirectories: true); try Data().write(to: derived)
        let owner = try await fixture.claim(job.id)
        try await fixture.store.persistDecodedMedia(jobID: job.id, owner: owner, derivedAudioPath: derived.path)
        try await fixture.store.transitionOwned(job.id, owner: owner, to: .ready)
        try await fixture.store.deleteMediaImport(jobID: job.id, jobsDirectory: fixture.root)
        #expect(!FileManager.default.fileExists(atPath: derived.path))
        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
        #expect(try await fixture.store.job(id: job.id) == nil)
    }

    @Test func failedDeletionClaimCanRetryAfterArtifactIsMadeSafe() async throws {
        let fixture = try MediaPipelineFixture(); let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString); try Data().write(to: outside)
        let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        let artifact = fixture.audioURL(job.id); try FileManager.default.createDirectory(at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true); try FileManager.default.createSymbolicLink(at: artifact, withDestinationURL: outside)
        let owner = try await fixture.claim(job.id); try await fixture.store.persistDecodedMedia(jobID: job.id, owner: owner, derivedAudioPath: artifact.path); try await fixture.store.transitionOwned(job.id, owner: owner, to: .ready)
        await #expect(throws: Error.self) { try await fixture.store.deleteMediaImport(jobID: job.id, jobsDirectory: fixture.root) }
        #expect(try await fixture.store.mediaDeletionError(jobID: job.id) != nil)
        try FileManager.default.removeItem(at: artifact); try Data().write(to: artifact)
        try await fixture.store.deleteMediaImport(jobID: job.id, jobsDirectory: fixture.root)
        #expect(try await fixture.store.job(id: job.id) == nil)
        #expect(FileManager.default.fileExists(atPath: outside.path))
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
    func claim(_ id: UUID) async throws -> UUID { let owner = UUID(); _ = try await store.claimQueuedJob(id, kind: .mediaImport, owner: owner, leaseDuration: 30); return owner }
    func pipeline(decoder: PipelineDecodeProbe = .init(), transcriber: PipelineTranscribeProbe = .init(), diarizer: PipelineDiarizeProbe = .init()) -> MediaImportPipeline {
        MediaImportPipeline(store: store, jobsDirectory: root, decoder: decoder, transcriber: transcriber, diarizer: diarizer, language: nil, model: "model")
    }
}

private actor PipelineDecodeProbe: MediaJobAudioDecoding {
    private(set) var calls = 0
    func decode(jobID: UUID, destination: URL, cancellation: CancellationToken, progress: @escaping @Sendable (Double) -> Void) async throws {
        calls += 1; try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true); try writeValidWAV(to: destination); progress(1)
    }
}

private func writeValidWAV(to url: URL) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
    buffer.frameLength = 160
    try file.write(from: buffer)
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

private actor LeaseExecutionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var starts = 0
    func execute(_ job: TranscriptionJob, _ token: CancellationToken) async throws { starts += 1; await withCheckedContinuation { continuation = $0 }; try token.checkCancellation() }
    func waitUntilStarted() async { while starts == 0 { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class MutableJobClock: JobClock, @unchecked Sendable {
    private let lock = NSLock(); private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance(by interval: TimeInterval) { lock.withLock { value = value.addingTimeInterval(interval) } }
}
