import Foundation
import Testing
@testable import FreeTalker

@Suite struct RecoveryRetryTests {
    @MainActor @Test func recoveredDictationMustPersistBeforeItsAudioCanBeFinalized() throws {
        // `duration: 3.5` here proves the field carries through `persistRecoveredDictation` to the
        // record boundary (`persisted == dictation` compares it). The upstream computation
        // (`samples.count / CaptureSegmentCodec.sampleRate` in `processRecoveredDictation`) stays
        // whisper-bound and isn't exercised here. See P2 finding 3.
        let dictation = RecoveryDictation(
            language: "pt", template: "Clean", transcript: "raw", refined: "refined",
            engine: "WhisperKit", duration: 3.5
        )
        var persisted: RecoveryDictation?

        try AppCoordinator.persistRecoveredDictation(dictation) { persisted = $0 }

        #expect(persisted == dictation)
        #expect(persisted?.duration == 3.5)
    }

    @MainActor @Test func recoveredDictationPersistenceFailureIsClassifiedAsPersisting() {
        let dictation = RecoveryDictation(
            language: "pt", template: "Clean", transcript: "raw", refined: "refined", engine: "WhisperKit"
        )

        do {
            try AppCoordinator.persistRecoveredDictation(dictation) { _ in throw RetryTestError.database }
            Issue.record("Expected persistence failure")
        } catch AppCoordinator.PipelineError.recordFailed {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @MainActor @Test func retryAppliesActivePostProcessorToTranscribedText() async throws {
        let transcriber = RecoveryLocalTranscriberProbe()
        let processor = RecoveryPostProcessorSpy(output: "polished text")

        let dictation = try await AppCoordinator.shared.processRecoveredDictation(
            samples: [0.1],
            configuration: .init(),
            captureID: UUID(),
            transcriber: transcriber,
            processor: processor,
            record: { _ in }
        )

        #expect(dictation.transcript == "local transcript")
        #expect(dictation.refined == "polished text")
        #expect(await processor.callCount == 1)
    }

    /// Codex round-5 finding 8: proves a persisted attempt's durable voice-command snapshot
    /// (`AttemptConfiguration.voiceCommandsEnabled`/`commandKeywords` — the job row written by
    /// `TranscriptionJobStore.beginAttempt`/`queueRecoveryRetry`) reaches the REAL
    /// `PostProcessingRequest` the active processor receives on retry, not just that some policy
    /// value is computed and discarded upstream.
    @MainActor @Test func persistedAttemptVoiceCommandSnapshotReachesTheRealPostProcessingRequest() async throws {
        let transcriber = RecoveryLocalTranscriberProbe()
        let processor = RecoveryPostProcessorSpy(output: "polished text")

        let dictation = try await AppCoordinator.shared.processRecoveredDictation(
            samples: [0.1],
            configuration: .init(voiceCommandsEnabled: true, commandKeywords: ["ordem"]),
            captureID: UUID(),
            transcriber: transcriber,
            processor: processor,
            record: { _ in }
        )

        #expect(await processor.lastRequest?.voiceCommandPolicy == .enabled(keywords: ["ordem"]))
        #expect(dictation.voiceCommandsActive == true)
    }

    @MainActor @Test func retryFallsBackToRawTranscriptWhenPostProcessingFails() async throws {
        let transcriber = RecoveryLocalTranscriberProbe()
        let processor = RecoveryPostProcessorSpy(error: RetryTestError.database)

        let dictation = try await AppCoordinator.shared.processRecoveredDictation(
            samples: [0.1],
            configuration: .init(),
            captureID: UUID(),
            transcriber: transcriber,
            processor: processor,
            record: { _ in }
        )

        #expect(dictation.transcript == "local transcript")
        #expect(dictation.refined == "local transcript")
    }

    @MainActor @Test func retryCancellationDuringPostProcessingNeverRecords() async throws {
        let transcriber = RecoveryLocalTranscriberProbe()
        let processor = RecoveryPostProcessorSpy(error: CancellationError())
        var recordCallCount = 0

        await #expect(throws: CancellationError.self) {
            try await AppCoordinator.shared.processRecoveredDictation(
                samples: [0.1],
                configuration: .init(),
                captureID: UUID(),
                transcriber: transcriber,
                processor: processor,
                record: { _ in recordCallCount += 1 }
            )
        }

        #expect(recordCallCount == 0)
    }

    @Test func recoveryLocalProcessorUsesExactLocalModelAndNoCloudBoundary() async throws {
        let local = RecoveryLocalTranscriberProbe()
        let cloudSTT = CloudBoundaryProbe()
        let cloudLLM = CloudBoundaryProbe()
        let output = try await RecoveryLocalProcessor(transcriber: local).process(
            samples: [0.1],
            configuration: .init(language: "pt", speechModel: "requested-small", template: "ignored"),
            defaultModel: "global-large"
        )
        #expect(output.text == "local transcript")
        #expect(await local.requests == ["pt|requested-small"])
        #expect(await cloudSTT.calls == 0)
        #expect(await cloudLLM.calls == 0)
    }
    @Test func oneRetryCreatesOneAttemptAndUsesOverrides() async throws {
        let fixture = try await RetryFixture()
        let configuration = AttemptConfiguration(language: "pt", speechModel: "small", template: "email")
        let probe = RetryProbe()
        let pipeline = fixture.pipeline(probe: probe)

        try await pipeline.execute(jobID: fixture.job.id, configuration: configuration, cancellation: CancellationToken())

        #expect(try await fixture.store.attempts(jobID: fixture.job.id).count == 1)
        #expect(probe.configurations == [configuration])
    }

    @Test func successfulRetryCommitsBeforeReadyAndDeletesExactSourceLast() async throws {
        let fixture = try await RetryFixture()
        let probe = RetryProbe()
        let pipeline = fixture.pipeline(probe: probe)

        try await pipeline.execute(jobID: fixture.job.id, configuration: .init(), cancellation: CancellationToken())

        #expect(probe.events == ["transcribe", "record", "remove:\(fixture.source.path)"])
        #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
        #expect(try await fixture.store.job(id: fixture.job.id)?.state == .ready)
    }

    @Test func postProcessFailurePersistsRawTranscript() async throws {
        let fixture = try await RetryFixture()
        let probe = RetryProbe(postProcessFails: true)
        let pipeline = fixture.pipeline(probe: probe)

        try await pipeline.execute(jobID: fixture.job.id, configuration: .init(), cancellation: CancellationToken())

        #expect(probe.recorded?.transcript == "raw words")
        #expect(probe.recorded?.refined == "raw words")
        #expect(try await fixture.store.job(id: fixture.job.id)?.state == .ready)
    }

    @Test func databaseFailurePreservesSourceAndFailsAttempt() async throws {
        let fixture = try await RetryFixture()
        let probe = RetryProbe(recordFails: true)
        let pipeline = fixture.pipeline(probe: probe)

        await #expect(throws: RetryTestError.database) {
            try await pipeline.execute(jobID: fixture.job.id, configuration: .init(), cancellation: CancellationToken())
        }

        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
        #expect(try await fixture.store.attempts(jobID: fixture.job.id).map(\.result) == [
            .failed(JobFailure(stage: .persisting, message: "database"))
        ])
    }

    @Test func restartWithObservableLibraryCaptureSkipsTranscriptionAndResumesFinalization() async throws {
        let fixture = try await RetryFixture()
        let probe = RetryProbe()
        let events = LockedRetryEvents()
        let pipeline = RecoveryRetryPipeline(
            directory: fixture.directory,
            store: fixture.store,
            loadSamples: { _ in
                Issue.record("Library-owned capture must not reload audio")
                return []
            },
            processDictation: probe.process,
            libraryDictationID: { captureID in
                #expect(captureID == fixture.job.id)
                return 77
            },
            finalizeJournalCapture: { captureID, libraryID in
                events.append("finalize:\(captureID.uuidString):\(libraryID)")
                return true
            }
        )

        try await pipeline.execute(
            jobID: fixture.job.id,
            configuration: .init(),
            cancellation: CancellationToken()
        )

        #expect(probe.configurations.isEmpty)
        #expect(events.values == ["finalize:\(fixture.job.id.uuidString):77"])
    }

    @Test func libraryInsertDurableThenThrowIsFoundOnRestartWithoutRetranscription() async throws {
        let fixture = try await RetryFixture()
        let library = try PersistentRetryLibrary(
            url: fixture.directory.appendingPathComponent("library.sqlite")
        )
        let pipeline = RecoveryRetryPipeline(
            directory: fixture.directory,
            store: fixture.store,
            loadSamples: { _ in [0.1] },
            processDictation: { _, _, captureID, _ in
                try library.persistThenThrow(captureID: captureID)
            },
            libraryDictationID: { captureID in
                library.dictationID(captureID: captureID)
            },
            finalizeJournalCapture: { captureID, libraryID in
                library.finalize(captureID: captureID, libraryID: libraryID)
            }
        )

        await #expect(throws: RetryTestError.database) {
            try await pipeline.execute(
                jobID: fixture.job.id, configuration: .init(),
                cancellation: CancellationToken()
            )
        }
        let reopened = try TranscriptionJobStore(
            databaseURL: fixture.databaseURL, clock: SystemJobClock()
        )
        #expect(try await reopened.recoverInterruptedJobs(kind: .recovery) == 1)
        try await reopened.transition(
            fixture.job.id, from: .queued, to: .processing(stage: .preparing)
        )
        let relaunched = RecoveryRetryPipeline(
            directory: fixture.directory,
            store: reopened,
            loadSamples: { _ in
                Issue.record("Relaunch must not reload Library-owned audio")
                return []
            },
            processDictation: { _, _, captureID, _ in
                try library.persistThenThrow(captureID: captureID)
            },
            libraryDictationID: { captureID in library.dictationID(captureID: captureID) },
            finalizeJournalCapture: { captureID, libraryID in
                library.finalize(captureID: captureID, libraryID: libraryID)
            }
        )
        try await relaunched.execute(
            jobID: fixture.job.id, configuration: .init(),
            cancellation: CancellationToken()
        )

        #expect(library.processCount == 1)
        #expect(library.finalizationCount == 1)
        #expect(try library.count(captureID: fixture.job.id) == 1)
    }

    @Test func libraryOwnedRecoveryWithoutJournalFinalizerUsesOneRunnerFinalizationAndNoTranscription() async throws {
        let fixture = try await RetryFixture()
        try await fixture.store.transition(
            fixture.job.id, from: .processing,
            to: .failed(.init(stage: .persisting, message: "restart"))
        )
        try await fixture.store.transition(fixture.job.id, from: .failed, to: .queued)
        let probe = RetryProbe()
        let pipeline = RecoveryRetryPipeline(
            directory: fixture.directory,
            store: fixture.store,
            loadSamples: { _ in
                Issue.record("Library-owned recovery must not reload audio")
                return []
            },
            processDictation: probe.process,
            libraryDictationID: { _ in 77 },
            finalizeJournalCapture: { _, _ in false }
        )
        let runner = LocalJobRunner(
            store: fixture.store, kind: .recovery,
            executorFinalizesJob: true
        ) { job, token in
            try await pipeline.execute(
                jobID: job.id, configuration: nil, cancellation: token
            )
        }

        await runner.enqueue(fixture.job.id)
        await runner.waitUntilIdle()

        #expect(probe.configurations.isEmpty)
        #expect(try await fixture.store.job(id: fixture.job.id)?.state == .ready)
        #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
    }

    @Test func interruptedRetryResumesTheSameAttemptWithPersistedOverrides() async throws {
        let fixture = try await RetryFixture()
        try await fixture.store.transition(fixture.job.id, from: .processing, to: .processing(stage: .transcribing))
        _ = try await fixture.store.beginAttempt(jobID: fixture.job.id, configuration: .init(language: "en"))

        #expect(try await fixture.store.recoverInterruptedJobs() == 1)
        try await fixture.store.transition(fixture.job.id, from: .queued, to: .processing(stage: .preparing))
        let probe = RetryProbe()
        try await fixture.pipeline(probe: probe).execute(
            jobID: fixture.job.id,
            configuration: .init(language: "fr", speechModel: "large", template: "override"),
            cancellation: CancellationToken()
        )

        let attempts = try await fixture.store.attempts(jobID: fixture.job.id)
        #expect(attempts.map(\.number) == [1])
        #expect(attempts[0].configuration.language == "en")
        #expect(attempts[0].result == .succeeded)
        #expect(probe.configurations.map(\.language) == ["en"])
    }

    @Test func readyTransactionFailureLeavesAttemptUnfinishedAndSourceIntact() async throws {
        let fixture = try await RetryFixture()
        let pipeline = fixture.pipeline(probe: RetryProbe(), failReadyTransaction: true)

        await #expect(throws: RetryTestError.database) {
            try await pipeline.execute(jobID: fixture.job.id, configuration: .init(), cancellation: CancellationToken())
        }

        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
        #expect(try await fixture.store.attempts(jobID: fixture.job.id).last?.result == nil)
        #expect(try await fixture.store.job(id: fixture.job.id)?.state == .processing(stage: .transcribing))
    }

    @Test func deletionFailureKeepsReadySuccessAndPersistsCleanupError() async throws {
        let fixture = try await RetryFixture()
        let pipeline = fixture.pipeline(probe: RetryProbe(), removalError: RetryTestError.database)

        try await pipeline.execute(jobID: fixture.job.id, configuration: .init(), cancellation: CancellationToken())

        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
        #expect(try await fixture.store.attempts(jobID: fixture.job.id).last?.result == .succeeded)
        let job = try #require(try await fixture.store.job(id: fixture.job.id))
        #expect(job.state == .ready)
        #expect(job.needsSourceCleanup)
        #expect(job.sourceCleanupError == "database")
    }

    @Test func launchCleanupRetryRemovesSourceAndClearsMetadata() async throws {
        let fixture = try await RetryFixture()
        try await fixture.pipeline(probe: RetryProbe(), removalError: RetryTestError.database)
            .execute(jobID: fixture.job.id, configuration: .init(), cancellation: CancellationToken())

        await fixture.pipeline(probe: RetryProbe()).retryPendingSourceCleanup()

        #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
        let job = try #require(try await fixture.store.job(id: fixture.job.id))
        #expect(!job.needsSourceCleanup)
        #expect(job.sourceCleanupError == nil)
    }

    @Test func cancellationAfterRecoveryFinalizationHandshakeIsTooLate() async throws {
        let fixture = try await RetryFixture()
        try await fixture.store.transition(
            fixture.job.id,
            from: .processing,
            to: .failed(JobFailure(stage: .preparing, message: "retry"))
        )
        try await fixture.store.transition(fixture.job.id, from: .failed, to: .queued)
        let store = SuspendedReadyRetryStore(base: fixture.store)
        let pipeline = RecoveryRetryPipeline(
            directory: fixture.directory,
            store: store,
            loadSamples: { _ in [0.1] },
            processDictation: RetryProbe().process
        )
        let runner = LocalJobRunner(store: store, kind: .recovery, executorFinalizesJob: true) { job, token in
            try await pipeline.execute(jobID: job.id, configuration: .init(), cancellation: token)
        }

        await runner.enqueue(fixture.job.id)
        await store.waitUntilReadyTransactionStarts()
        let outcome = await runner.cancel(fixture.job.id)
        await store.resumeReadyTransaction()
        await runner.waitUntilIdle()

        #expect(outcome == .tooLate)
        #expect(try await fixture.store.job(id: fixture.job.id)?.state == .ready)
    }

    @Test func pipelineReadyRollbackImmediatelyFailsJobAndUnfinishedAttempt() async throws {
        let fixture = try await RetryFixture()
        try await fixture.store.transition(
            fixture.job.id,
            from: .processing,
            to: .failed(JobFailure(stage: .preparing, message: "retry"))
        )
        try await fixture.store.transition(fixture.job.id, from: .failed, to: .queued)
        let retryStore = FailingReadyStore(base: fixture.store)
        let pipeline = RecoveryRetryPipeline(
            directory: fixture.directory,
            store: retryStore,
            loadSamples: { _ in [0.1] },
            processDictation: RetryProbe().process,
            errorStage: { _ in .transcribing }
        )
        let runner = LocalJobRunner(
            store: fixture.store,
            kind: .recovery,
            executorFinalizesJob: true,
            finalizationFailure: pipeline.failFinalization
        ) { job, token in
            try await pipeline.execute(jobID: job.id, configuration: .init(), cancellation: token)
        }

        await runner.enqueue(fixture.job.id)
        await runner.waitUntilIdle()

        #expect(try await fixture.store.job(id: fixture.job.id)?.state == .failed(
            JobFailure(stage: .persisting, message: "database")
        ))
        #expect(try await fixture.store.attempts(jobID: fixture.job.id).last?.result == .failed(
            JobFailure(stage: .persisting, message: "database")
        ))
    }

    /// P2 regression: a heartbeat lease-renewal failure calls `token.cancel()` directly
    /// (`LocalJobRunner.execute`'s heartbeat task), bypassing `LocalJobRunner.cancel(_:)`'s
    /// executing/finalizing phase check entirely. Before the fix, `RecoveryRetryPipeline` only
    /// consulted the token *after* `processDictation` returned — so a token cancelled while
    /// `processDictation` (i.e. `AppCoordinator.processRecoveredDictation`) was still running
    /// could not stop the irreversible Library insert it performs internally. This suspends the
    /// processor mid-flight, cancels the token exactly as the heartbeat would, and asserts the
    /// record closure is never reached and the job ends up cancelled — not silently `.ready`
    /// with a Library row.
    @Test func directTokenCancellationDuringProcessDictationNeverRecordsAndEndsCancelled() async throws {
        let fixture = try await RetryFixture()
        // `RetryFixture` leaves the job in `.processing` (see its `init`). `LocalJobRunner.execute`
        // only picks up jobs in `.queued` state, so route back through `.failed` → `.queued` first —
        // mirrors `cancellationAfterRecoveryFinalizationHandshakeIsTooLate` and
        // `pipelineReadyRollbackImmediatelyFailsJobAndUnfinishedAttempt` above.
        try await fixture.store.transition(
            fixture.job.id,
            from: .processing,
            to: .failed(JobFailure(stage: .preparing, message: "retry"))
        )
        try await fixture.store.transition(fixture.job.id, from: .failed, to: .queued)
        let gate = ProcessingSuspensionGate()
        let recorded = RecordedFlag()
        let pipeline = RecoveryRetryPipeline(
            directory: fixture.directory,
            store: fixture.store,
            loadSamples: { _ in [0.1] },
            processDictation: { _, _, _, checkCancellation in
                await gate.signalSuspended()
                await gate.waitForRelease()
                // Mirrors `AppCoordinator.processRecoveredDictation`'s check immediately before
                // its irreversible `persistRecoveredDictation` call.
                try checkCancellation()
                await recorded.markRecorded()
                return RecoveryDictation(
                    language: "pt", template: "Clean", transcript: "raw", refined: "raw", engine: "test"
                )
            }
        )
        let tokenBox = CancellationTokenBox()
        let runner = LocalJobRunner(store: fixture.store, kind: .recovery, executorFinalizesJob: true) { job, token in
            await tokenBox.set(token)
            try await pipeline.execute(jobID: job.id, configuration: .init(), cancellation: token)
        }

        await runner.enqueue(fixture.job.id)
        await gate.waitUntilSuspended()
        // Simulate the heartbeat's direct `token.cancel()` on lease-renewal failure — not
        // `runner.cancel(_:)`, which enforces the executing/finalizing phase boundary instead.
        await tokenBox.cancel()
        await gate.release()
        await runner.waitUntilIdle()

        #expect(await recorded.value == false)
        #expect(try await fixture.store.job(id: fixture.job.id)?.state == .cancelled)
    }
}

private actor RecoveryLocalTranscriberProbe: RecoveryLocalTranscribing {
    private(set) var requests: [String] = []
    func transcribe(samples: [Float], forcedLanguage: String?, candidateLanguages: [String], exactModel: String) async throws -> TranscriptionOutput {
        requests.append("\(forcedLanguage ?? "auto")|\(exactModel)")
        return .init(text: "local transcript", language: forcedLanguage ?? "en")
    }
}

private actor CloudBoundaryProbe {
    private(set) var calls = 0
    func call() { calls += 1 }
}

private actor RecoveryPostProcessorSpy: PostProcessor {
    private let output: String?
    private let error: Error?
    private(set) var callCount = 0
    // Codex round-5 finding 8: captures the REAL request the processor received, so a test can
    // assert a persisted attempt's voice-command snapshot actually reaches it, not just that some
    // policy value was computed somewhere upstream.
    private(set) var lastRequest: PostProcessingRequest?

    init(output: String) { self.output = output; error = nil }
    init(error: Error) { output = nil; self.error = error }

    func process(_ request: PostProcessingRequest) async throws -> String {
        callCount += 1
        lastRequest = request
        if let error { throw error }
        return output ?? ""
    }
}

private final class PersistentRetryLibrary: @unchecked Sendable {
    private let lock = NSLock()
    let url: URL
    private var storedProcessCount = 0
    private var storedFinalizationCount = 0
    var processCount: Int { lock.withLock { storedProcessCount } }
    var finalizationCount: Int { lock.withLock { storedFinalizationCount } }

    init(url: URL) throws {
        self.url = url
        _ = try Database(path: url)
    }

    func persistThenThrow(captureID: UUID) throws -> RecoveryDictation {
        lock.withLock { storedProcessCount += 1 }
        let db = try Database(path: url)
        _ = try db.insertDictation(.init(
            timestamp: Date(timeIntervalSince1970: 55),
            sourceLanguage: SourceLanguage("en"),
            requestedOutputLanguage: .sameAsSpoken,
            template: "Clean", transcript: "raw", refined: "refined",
            engine: "local", sourceID: nil
        ), captureID: captureID)
        throw RetryTestError.database
    }

    func dictationID(captureID: UUID) -> Int64? {
        try? Database(path: url).dictations(captureID: captureID).first?.id
    }

    func finalize(captureID: UUID, libraryID: Int64) -> Bool {
        guard dictationID(captureID: captureID) == libraryID else { return false }
        lock.withLock { storedFinalizationCount += 1 }
        return true
    }

    func count(captureID: UUID) throws -> Int {
        try Database(path: url).dictations(captureID: captureID).count
    }
}

private enum RetryTestError: Error, LocalizedError {
    case database

    var errorDescription: String? { "database" }
}

private final class LockedRetryEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

/// Coordinates a test with a `processDictation` closure that must be suspended mid-flight so a
/// token cancellation can be injected before it resumes — mirrors the real timing window between
/// transcription/post-processing starting and the Library insert it performs.
private actor ProcessingSuspensionGate {
    private var isSuspended = false
    private var suspendedContinuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func signalSuspended() {
        isSuspended = true
        suspendedContinuation?.resume()
        suspendedContinuation = nil
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { suspendedContinuation = $0 }
    }

    func waitForRelease() async {
        guard !isReleased else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CancellationTokenBox {
    private var token: CancellationToken?
    func set(_ token: CancellationToken) { self.token = token }
    func cancel() { token?.cancel() }
}

private actor RecordedFlag {
    private(set) var value = false
    func markRecorded() { value = true }
}

private final class RetryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedConfigurations: [AttemptConfiguration] = []
    private var storedEvents: [String] = []
    private var storedRecorded: (transcript: String, refined: String)?
    var configurations: [AttemptConfiguration] { lock.withLock { storedConfigurations } }
    var events: [String] { lock.withLock { storedEvents } }
    var recorded: (transcript: String, refined: String)? { lock.withLock { storedRecorded } }
    let postProcessFails: Bool
    let recordFails: Bool

    init(postProcessFails: Bool = false, recordFails: Bool = false) {
        self.postProcessFails = postProcessFails
        self.recordFails = recordFails
    }

    func process(
        samples: [Float], configuration: AttemptConfiguration, captureID: UUID,
        checkCancellation: () throws -> Void
    ) async throws -> RecoveryDictation {
        try checkCancellation()
        lock.withLock {
            storedConfigurations.append(configuration)
            storedEvents.append("transcribe")
        }
        let refined = postProcessFails ? "raw words" : "refined words"
        lock.withLock { storedEvents.append("record") }
        if recordFails { throw RetryTestError.database }
        lock.withLock { storedRecorded = ("raw words", refined) }
        return RecoveryDictation(language: "pt", template: configuration.template ?? "Clean", transcript: "raw words", refined: refined, engine: configuration.speechModel ?? "default")
    }

    func removed(_ url: URL) throws {
        lock.withLock { storedEvents.append("remove:\(url.path)") }
        try FileManager.default.removeItem(at: url)
    }
}

private struct RetryFixture {
    let directory: URL
    let source: URL
    let store: TranscriptionJobStore
    let databaseURL: URL
    let job: TranscriptionJob

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appending(path: "\(UUID().uuidString).wav")
        try Data([1, 2, 3]).write(to: source)
        databaseURL = directory.appending(path: "jobs.sqlite")
        store = try TranscriptionJobStore(databaseURL: databaseURL, clock: SystemJobClock())
        job = try await store.create(kind: .recovery, source: .init(reference: source.path), now: Date())
        try await store.transition(job.id, from: .queued, to: .processing(stage: .preparing))
    }

    func pipeline(
        probe: RetryProbe,
        failReadyTransaction: Bool = false,
        removalError: (any Error)? = nil
    ) -> RecoveryRetryPipeline {
        let retryStore: any RecoveryRetryStoring = failReadyTransaction
            ? FailingReadyStore(base: store)
            : store
        return RecoveryRetryPipeline(
            directory: directory,
            store: retryStore,
            loadSamples: { _ in [0.1] },
            processDictation: probe.process,
            removeSource: { url in
                if let removalError { throw removalError }
                try probe.removed(url)
            }
        )
    }


}

private struct FailingReadyStore: RecoveryRetryStoring {
    let base: TranscriptionJobStore
    func job(id: UUID) async throws -> TranscriptionJob? { try await base.job(id: id) }
    func transition(_ id: UUID, from: JobState.Kind, to state: JobState) async throws { try await base.transition(id, from: from, to: state) }
    func beginAttempt(jobID: UUID, configuration: AttemptConfiguration) async throws -> JobAttempt { try await base.beginAttempt(jobID: jobID, configuration: configuration) }
    func finishAttempt(_ id: Int64, result: AttemptResult) async throws { try await base.finishAttempt(id, result: result) }
    func latestUnfinishedAttempt(jobID: UUID) async throws -> JobAttempt? { try await base.latestUnfinishedAttempt(jobID: jobID) }
    func completeAttemptAndMarkJobReady(jobID: UUID, attemptID: Int64) async throws { throw RetryTestError.database }
    func failAttemptAndMarkJobFailed(jobID: UUID, attemptID: Int64, failure: JobFailure) async throws { try await base.failAttemptAndMarkJobFailed(jobID: jobID, attemptID: attemptID, failure: failure) }
    func recordSourceCleanupError(jobID: UUID, message: String) async throws { try await base.recordSourceCleanupError(jobID: jobID, message: message) }
    func completeSourceCleanup(jobID: UUID) async throws { try await base.completeSourceCleanup(jobID: jobID) }
    func jobsNeedingSourceCleanup() async throws -> [TranscriptionJob] { try await base.jobsNeedingSourceCleanup() }
}

private actor SuspendedReadyRetryStore: RecoveryRetryStoring, TranscriptionJobStoring {
    let base: TranscriptionJobStore
    private var readyStarted = false
    private var readyContinuation: CheckedContinuation<Void, Never>?

    init(base: TranscriptionJobStore) { self.base = base }

    func job(id: UUID) async throws -> TranscriptionJob? { try await base.job(id: id) }
    func jobs(kind: JobKind?) async throws -> [TranscriptionJob] { try await base.jobs(kind: kind) }
    func transition(_ id: UUID, from: JobState.Kind, to state: JobState) async throws { try await base.transition(id, from: from, to: state) }
    func recoverInterruptedJobs(kind: JobKind?) async throws -> Int { try await base.recoverInterruptedJobs(kind: kind) }
    func beginAttempt(jobID: UUID, configuration: AttemptConfiguration) async throws -> JobAttempt { try await base.beginAttempt(jobID: jobID, configuration: configuration) }
    func finishAttempt(_ id: Int64, result: AttemptResult) async throws { try await base.finishAttempt(id, result: result) }
    func latestUnfinishedAttempt(jobID: UUID) async throws -> JobAttempt? { try await base.latestUnfinishedAttempt(jobID: jobID) }
    func completeAttemptAndMarkJobReady(jobID: UUID, attemptID: Int64) async throws {
        readyStarted = true
        await withCheckedContinuation { readyContinuation = $0 }
        try await base.completeAttemptAndMarkJobReady(jobID: jobID, attemptID: attemptID)
    }
    func failAttemptAndMarkJobFailed(jobID: UUID, attemptID: Int64, failure: JobFailure) async throws { try await base.failAttemptAndMarkJobFailed(jobID: jobID, attemptID: attemptID, failure: failure) }
    func recordSourceCleanupError(jobID: UUID, message: String) async throws { try await base.recordSourceCleanupError(jobID: jobID, message: message) }
    func completeSourceCleanup(jobID: UUID) async throws { try await base.completeSourceCleanup(jobID: jobID) }
    func jobsNeedingSourceCleanup() async throws -> [TranscriptionJob] { try await base.jobsNeedingSourceCleanup() }
    func waitUntilReadyTransactionStarts() async { while !readyStarted { await Task.yield() } }
    func resumeReadyTransaction() { readyContinuation?.resume(); readyContinuation = nil }
}
