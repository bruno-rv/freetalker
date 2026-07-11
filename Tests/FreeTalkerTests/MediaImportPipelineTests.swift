@preconcurrency import AVFoundation
import Darwin
import Foundation
import Testing
@testable import FreeTalker

@Suite struct MediaImportPipelineTests {
    @Test func promotedAudioWithoutCheckpointIsAdoptedAfterRestart() async throws {
        let fixture = try MediaPipelineFixture(); let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        try FileManager.default.createDirectory(at: fixture.jobDirectory(job.id), withIntermediateDirectories: true); try writeValidWAV(to: fixture.audioURL(job.id))
        let decoder = PipelineDecodeProbe(); let runner = fixture.pipeline(decoder: decoder).localJobRunner(); await runner.enqueue(job.id); await runner.waitUntilIdle()
        #expect(await decoder.calls == 0)
        #expect(try await fixture.store.completedMediaStages(jobID: job.id).contains(.decode))
        #expect(try await fixture.store.job(id: job.id)?.state == .ready)
    }

    @Test func adoptionPersistenceFailureRetainsAudioAndRetryConverges() async throws {
        let fixture = try MediaPipelineFixture(); let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        let owner = try await fixture.claim(job.id); try FileManager.default.createDirectory(at: fixture.jobDirectory(job.id), withIntermediateDirectories: true); try writeValidWAV(to: fixture.audioURL(job.id))
        let failing = AdoptionFailingStore(base: fixture.store); let decoder = PipelineDecodeProbe(); let token = CancellationToken(); token.installLeaseOwner(owner)
        let first = MediaImportPipeline(store: failing, jobsDirectory: fixture.root, decoder: decoder, transcriber: PipelineTranscribeProbe(), diarizer: PipelineDiarizeProbe(), language: nil, model: "model")
        await #expect(throws: AdoptionFailure.self) { try await first.execute(job: try #require(await fixture.store.job(id: job.id)), cancellation: token) }
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL(job.id).path))
        let retry = fixture.pipeline(decoder: decoder); try await retry.execute(job: try #require(await fixture.store.job(id: job.id)), cancellation: token)
        #expect(await decoder.calls == 0)
        #expect(try await fixture.store.job(id: job.id)?.state == .ready)
    }

    @Test func promotedAudioSurvivesLeaseTransferAndSuccessorAdopts() async throws {
        let clock = MutableJobClock(Date(timeIntervalSince1970: 300)); let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try TranscriptionJobStore(databaseURL: root.appendingPathComponent("jobs.sqlite"), clock: clock)
        let job = try await store.create(kind: .mediaImport, source: .init(reference: "/source.wav"), now: clock.now)
        let ownerA = UUID(); _ = try await store.claimQueuedJob(job.id, kind: .mediaImport, owner: ownerA, leaseDuration: 5)
        let transfer = LeaseTransferProbe()
        let fenced = AdoptionFailingStore(base: store) {
            clock.advance(by: 6); _ = try await store.recoverStaleJobs(kind: .mediaImport)
            let ownerB = UUID(); _ = try await store.claimQueuedJob(job.id, kind: .mediaImport, owner: ownerB, leaseDuration: 30); await transfer.record(ownerB)
        }
        let decoder = PipelineDecodeProbe(); let tokenA = CancellationToken(); tokenA.installLeaseOwner(ownerA)
        let pipelineA = MediaImportPipeline(store: fenced, jobsDirectory: root, decoder: decoder, transcriber: PipelineTranscribeProbe(), diarizer: PipelineDiarizeProbe(), language: nil, model: "model")
        await #expect(throws: JobStoreError.leaseLost) { try await pipelineA.execute(job: try #require(await store.job(id: job.id)), cancellation: tokenA) }
        let audio = root.appendingPathComponent(job.id.uuidString).appendingPathComponent("audio.wav")
        #expect(FileManager.default.fileExists(atPath: audio.path))
        let ownerB = try #require(await transfer.owner); let tokenB = CancellationToken(); tokenB.installLeaseOwner(ownerB)
        let pipelineB = MediaImportPipeline(store: store, jobsDirectory: root, decoder: decoder, transcriber: PipelineTranscribeProbe(), diarizer: PipelineDiarizeProbe(), language: nil, model: "model")
        try await pipelineB.execute(job: try #require(await store.job(id: job.id)), cancellation: tokenB)
        #expect(await decoder.calls == 1)
        #expect(try await store.job(id: job.id)?.state == .ready)
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test func invalidOrSymlinkOrphansAreNeverAdopted() async throws {
        for symlink in [false, true] {
            let fixture = try MediaPipelineFixture(); let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString); try Data("outside".utf8).write(to: outside)
            let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now); try FileManager.default.createDirectory(at: fixture.jobDirectory(job.id), withIntermediateDirectories: true)
            if symlink { try FileManager.default.createSymbolicLink(at: fixture.audioURL(job.id), withDestinationURL: outside) } else { try Data("bad".utf8).write(to: fixture.audioURL(job.id)) }
            let decoder = PipelineDecodeProbe(); let runner = fixture.pipeline(decoder: decoder).localJobRunner(); await runner.enqueue(job.id); await runner.waitUntilIdle()
            #expect(await decoder.calls == 1); #expect(try await fixture.store.job(id: job.id)?.state == .ready); #expect(try Data(contentsOf: outside) == Data("outside".utf8))
        }
    }

    @Test func wavWriterAcceptsAlignedLimitAndRejectsNextBlock() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR); defer { Darwin.close(descriptor); try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: true)!; let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!; block.frameLength = 1
        let alignedMaximum = PCMWAVFileWriter.maximumDataBytes & ~UInt64(3)
        let accepted = try PCMWAVFileWriter(descriptor: descriptor, initialDataBytes: alignedMaximum - 4); try accepted.write(block)
        let rejected = try PCMWAVFileWriter(descriptor: descriptor, initialDataBytes: alignedMaximum)
        #expect(throws: MediaImportError.self) { try rejected.write(block) }
    }
    @Test func productionDecoderWritesNormalizedAudioThroughPreopenedDescriptor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = try OwnedJobDirectory(root: root, jobID: UUID(), create: true); let temporary = try directory.createTemporaryFile()
        defer { directory.discard(temporary); directory.close(temporary) }
        let source = try #require(Bundle.module.url(forResource: "tone", withExtension: "wav", subdirectory: "Fixtures"))
        try await AVAudioDecoder().decode(source: source, destination: temporary.url, progress: { _ in }, cancellation: CancellationToken())
        #expect(directory.isNormalizedWAV(temporary))
        var info = stat(); #expect(fstat(temporary.descriptor, &info) == 0)
        var header = [UInt8](repeating: 0, count: 44); #expect(pread(temporary.descriptor, &header, header.count, 0) == 44)
        let riffSize = UInt32(header[4]) | UInt32(header[5]) << 8 | UInt32(header[6]) << 16 | UInt32(header[7]) << 24
        let dataSize = UInt32(header[40]) | UInt32(header[41]) << 8 | UInt32(header[42]) << 16 | UInt32(header[43]) << 24
        #expect(UInt64(riffSize) + 8 == UInt64(info.st_size))
        #expect(UInt64(dataSize) + 44 == UInt64(info.st_size))
        #expect(dataSize > 0 && dataSize % 4 == 0)
    }

    @Test func cancelledDescriptorDecodesCloseDuplicatesAndCleanStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try #require(Bundle.module.url(forResource: "tone", withExtension: "wav", subdirectory: "Fixtures"))
        for _ in 0..<5 {
            let directory = try OwnedJobDirectory(root: root, jobID: UUID(), create: true); let temporary = try directory.createTemporaryFile(); let token = CancellationToken(); token.cancel()
            await #expect(throws: CancellationError.self) { try await AVAudioDecoder().decode(source: source, destination: temporary.url, progress: { _ in }, cancellation: token) }
            directory.discard(temporary); directory.close(temporary)
            #expect((try FileManager.default.contentsOfDirectory(atPath: directory.directoryURL.path)).isEmpty)
        }
    }
    @Test func symlinkedJobDirectoryIsRejectedBeforeDecode() async throws {
        let fixture = try MediaPipelineFixture(); let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        try FileManager.default.createSymbolicLink(at: fixture.jobDirectory(job.id), withDestinationURL: outside)
        let decoder = PipelineDecodeProbe(); let runner = fixture.pipeline(decoder: decoder).localJobRunner(); await runner.enqueue(job.id); await runner.waitUntilIdle()
        #expect(await decoder.calls == 0)
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("audio.wav").path))
    }

    @Test func symlinkedDestinationCannotOverwriteOutsideFile() async throws {
        let fixture = try MediaPipelineFixture(); let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("outside".utf8).write(to: outside)
        let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        try FileManager.default.createDirectory(at: fixture.jobDirectory(job.id), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.audioURL(job.id), withDestinationURL: outside)
        let runner = fixture.pipeline().localJobRunner(); await runner.enqueue(job.id); await runner.waitUntilIdle()
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
        #expect(try await fixture.store.job(id: job.id)?.state == .ready)
    }

    @Test func directorySwapAfterTempOpenCannotRedirectDecodeOrInference() async throws {
        let fixture = try MediaPipelineFixture(); let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        let decoder = DirectorySwapDecoder(root: fixture.root, jobID: job.id, outside: outside)
        let runner = fixture.pipeline(decoder: decoder).localJobRunner(); await runner.enqueue(job.id); await runner.waitUntilIdle()
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("audio.wav").path))
        #expect(try await fixture.store.job(id: job.id)?.state.kind == .failed)
        #expect(try await fixture.store.completedMediaStages(jobID: job.id).isEmpty)
        let moved = fixture.root.appendingPathComponent(job.id.uuidString + "-moved")
        #expect((try FileManager.default.contentsOfDirectory(atPath: moved.path)).isEmpty)
    }
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
        await #expect(throws: JobStoreError.leaseLost) { try await store.finalizeMediaImport(jobID: job.id, owner: oldOwner) }
        try await store.updateMediaProgress(jobID: job.id, owner: newOwner, progress: 0.2)
        #expect(try await store.job(id: job.id)?.progress == 0.2)
    }

    @Test func recoveryAttemptFinalizationIsFencedAcrossOwners() async throws {
        let clock = MutableJobClock(Date(timeIntervalSince1970: 200)); let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try TranscriptionJobStore(databaseURL: root.appendingPathComponent("jobs.sqlite"), clock: clock)
        let job = try await store.create(kind: .recovery, source: .init(reference: "/recovery.wav"), now: clock.now)
        let old = UUID(); _ = try await store.claimQueuedJob(job.id, kind: .recovery, owner: old, leaseDuration: 5)
        let attempt = try await store.beginOwnedAttempt(jobID: job.id, owner: old, configuration: .init())
        clock.advance(by: 6); #expect(try await store.recoverStaleJobs(kind: .recovery) == 1)
        let new = UUID(); _ = try await store.claimQueuedJob(job.id, kind: .recovery, owner: new, leaseDuration: 5)
        await #expect(throws: JobStoreError.leaseLost) { try await store.completeOwnedAttemptAndJob(jobID: job.id, owner: old, attemptID: attempt.id) }
        try await store.completeOwnedAttemptAndJob(jobID: job.id, owner: new, attemptID: attempt.id)
        #expect(try await store.job(id: job.id)?.state == .ready)
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

    @Test func runnerPublishesMeaningfulIntermediateStageAndProgressChanges() async throws {
        let fixture = try MediaPipelineFixture()
        let job = try await fixture.store.create(kind: .mediaImport, source: .init(reference: fixture.source.path), now: .now)
        let observed = PipelineObservationProbe(store: fixture.store)
        let pipeline = fixture.pipeline(decoder: ProgressPipelineDecoder())
        let runner = pipeline.localJobRunner { id in await observed.record(id) }

        await runner.enqueue(job.id)
        await runner.waitUntilIdle()
        await observed.waitForTerminal()

        let snapshots = await observed.snapshots
        #expect(snapshots.contains { $0.state == .processing(stage: .decoding) && $0.progress > 0 && $0.progress < 0.25 })
        #expect(snapshots.contains { $0.state == .processing(stage: .transcribing) })
        #expect(snapshots.contains { $0.state == .processing(stage: .diarizing) && $0.progress >= 0.5 })
        #expect(snapshots.last?.state == .ready)
        #expect(snapshots.count < 20)
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
        #expect(!FileManager.default.fileExists(atPath: derived.path))
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
        let first = fixture.jobDirectory(job.id).appendingPathComponent("a.wav"); let artifact = fixture.jobDirectory(job.id).appendingPathComponent("z.wav")
        try FileManager.default.createDirectory(at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true); try Data().write(to: first); try FileManager.default.createSymbolicLink(at: artifact, withDestinationURL: outside)
        let owner = try await fixture.claim(job.id); try await fixture.store.persistDecodedMedia(jobID: job.id, owner: owner, derivedAudioPath: first.path); try await fixture.store.persistDecodedMedia(jobID: job.id, owner: owner, derivedAudioPath: artifact.path); try await fixture.store.transitionOwned(job.id, owner: owner, to: .ready)
        await #expect(throws: Error.self) { try await fixture.store.deleteMediaImport(jobID: job.id, jobsDirectory: fixture.root) }
        #expect(try await fixture.store.mediaDeletionError(jobID: job.id) != nil)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        try FileManager.default.removeItem(at: artifact); try Data().write(to: artifact)
        try await fixture.store.deleteMediaImport(jobID: job.id, jobsDirectory: fixture.root)
        #expect(try await fixture.store.job(id: job.id) == nil)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}

private enum PipelineTestError: Error, LocalizedError { case failed; var errorDescription: String? { "failed" } }
private enum AdoptionFailure: Error { case injected }

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
    func pipeline(decoder: any MediaJobAudioDecoding = PipelineDecodeProbe(), transcriber: any TimestampedTranscribing = PipelineTranscribeProbe(), diarizer: any SpeakerDiarizing = PipelineDiarizeProbe()) -> MediaImportPipeline {
        MediaImportPipeline(store: store, jobsDirectory: root, decoder: decoder, transcriber: transcriber, diarizer: diarizer, language: nil, model: "model")
    }
}

private actor PipelineDecodeProbe: MediaJobAudioDecoding {
    private(set) var calls = 0
    func decode(jobID: UUID, destination: URL, cancellation: CancellationToken, progress: @escaping @Sendable (Double) -> Void) async throws {
        calls += 1; try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true); try writeValidWAV(to: destination); progress(1)
    }
}

private actor ProgressPipelineDecoder: MediaJobAudioDecoding {
    func decode(jobID: UUID, destination: URL, cancellation: CancellationToken, progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeValidWAV(to: destination)
        progress(0.2); try await Task.sleep(for: .milliseconds(10))
        progress(0.21); try await Task.sleep(for: .milliseconds(10))
        progress(0.8); try await Task.sleep(for: .milliseconds(10))
        progress(1); try await Task.sleep(for: .milliseconds(10))
    }
}

private actor PipelineObservationProbe {
    let store: TranscriptionJobStore
    private(set) var snapshots: [TranscriptionJob] = []
    init(store: TranscriptionJobStore) { self.store = store }
    func record(_ id: UUID) async {
        if let job = try? await store.job(id: id) { snapshots.append(job) }
    }
    func waitForTerminal() async {
        while snapshots.last?.state.kind != .ready { await Task.yield() }
    }
}

private struct DirectorySwapDecoder: MediaJobAudioDecoding {
    let root: URL; let jobID: UUID; let outside: URL
    func decode(jobID: UUID, destination: URL, cancellation: CancellationToken, progress: @escaping @Sendable (Double) -> Void) async throws {
        let original = root.appendingPathComponent(jobID.uuidString); let moved = root.appendingPathComponent(jobID.uuidString + "-moved")
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
        try writeValidWAV(to: destination); progress(1)
    }
}

private func writeValidWAV(to url: URL) throws {
    if url.path.hasPrefix("/dev/fd/") {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writeValidWAV(to: temporary)
        let data = try Data(contentsOf: temporary)
        guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) >= 0 else { throw POSIXError(.EIO) }
        try data.withUnsafeBytes { bytes in
            guard Darwin.write(descriptor, bytes.baseAddress, bytes.count) == bytes.count else { throw POSIXError(.EIO) }
        }
        _ = lseek(descriptor, 0, SEEK_SET)
        return
    }
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

private actor AdoptionFailingStore: MediaImportPipelineStoring {
    let base: TranscriptionJobStore; private var shouldFail = true; private let transfer: (@Sendable () async throws -> Void)?
    init(base: TranscriptionJobStore, transfer: (@Sendable () async throws -> Void)? = nil) { self.base = base; self.transfer = transfer }
    func job(id: UUID) async throws -> TranscriptionJob? { try await base.job(id: id) }
    func jobs(kind: JobKind?) async throws -> [TranscriptionJob] { try await base.jobs(kind: kind) }
    func transition(_ id: UUID, from: JobState.Kind, to state: JobState) async throws { try await base.transition(id, from: from, to: state) }
    func recoverInterruptedJobs(kind: JobKind?) async throws -> Int { try await base.recoverInterruptedJobs(kind: kind) }
    func completedMediaStages(jobID: UUID) async throws -> Set<MediaPipelineStage> { try await base.completedMediaStages(jobID: jobID) }
    func isDerivedMediaRegistered(jobID: UUID, path: String) async throws -> Bool { try await base.isDerivedMediaRegistered(jobID: jobID, path: path) }
    func advanceMediaStage(jobID: UUID, owner: UUID, stage: JobStage) async throws { try await base.advanceMediaStage(jobID: jobID, owner: owner, stage: stage) }
    func updateMediaProgress(jobID: UUID, owner: UUID, progress: Double) async throws { try await base.updateMediaProgress(jobID: jobID, owner: owner, progress: progress) }
    func persistDecodedMedia(jobID: UUID, owner: UUID, derivedAudioPath: String) async throws { if shouldFail { shouldFail = false; if let transfer { try await transfer(); throw JobStoreError.leaseLost }; throw AdoptionFailure.injected }; try await base.persistDecodedMedia(jobID: jobID, owner: owner, derivedAudioPath: derivedAudioPath) }
    func persistTranscript(jobID: UUID, owner: UUID, segments: [TranscriptSegment]) async throws { try await base.persistTranscript(jobID: jobID, owner: owner, segments: segments) }
    func persistSpeakerTurns(jobID: UUID, owner: UUID, turns: [SpeakerTurn]) async throws { try await base.persistSpeakerTurns(jobID: jobID, owner: owner, turns: turns) }
    func finalizeMediaImport(jobID: UUID, owner: UUID) async throws { try await base.finalizeMediaImport(jobID: jobID, owner: owner) }
    func invalidateInvalidDecodedMedia(jobID: UUID, owner: UUID) async throws { try await base.invalidateInvalidDecodedMedia(jobID: jobID, owner: owner) }
}

private actor LeaseTransferProbe { private(set) var owner: UUID?; func record(_ owner: UUID) { self.owner = owner } }
