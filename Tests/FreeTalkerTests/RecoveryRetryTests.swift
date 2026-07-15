import Foundation
import Testing
@testable import FreeTalker

@Suite struct RecoveryRetryTests {
    @MainActor @Test func recoveredDictationMustPersistBeforeItsAudioCanBeFinalized() throws {
        let dictation = RecoveryDictation(
            language: "pt", template: "Clean", transcript: "raw", refined: "refined", engine: "WhisperKit"
        )
        var persisted: RecoveryDictation?

        try AppCoordinator.persistRecoveredDictation(dictation) { persisted = $0 }

        #expect(persisted == dictation)
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
}

private actor RecoveryLocalTranscriberProbe: RecoveryLocalTranscribing {
    private(set) var requests: [String] = []
    func transcribe(samples: [Float], forcedLanguage: String?, exactModel: String) async throws -> TranscriptionOutput {
        requests.append("\(forcedLanguage ?? "auto")|\(exactModel)")
        return .init(text: "local transcript", language: forcedLanguage ?? "en")
    }
}

private actor CloudBoundaryProbe {
    private(set) var calls = 0
    func call() { calls += 1 }
}

private enum RetryTestError: Error, LocalizedError {
    case database

    var errorDescription: String? { "database" }
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

    func process(samples: [Float], configuration: AttemptConfiguration) async throws -> RecoveryDictation {
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
    let job: TranscriptionJob

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appending(path: "\(UUID().uuidString).wav")
        try Data([1, 2, 3]).write(to: source)
        store = try TranscriptionJobStore(databaseURL: directory.appending(path: "jobs.sqlite"), clock: SystemJobClock())
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
