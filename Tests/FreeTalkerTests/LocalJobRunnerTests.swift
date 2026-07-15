import Foundation
import Testing
@testable import FreeTalker

@Suite struct LocalJobRunnerTests {
    @Test func shutdownDrainsCurrentWorkAndLeavesQueuedJobsForFreshRunner() async throws {
        let fixture = try RunnerFixture()
        let current = try await fixture.makeJob(.recovery, "current-rebind.wav")
        let queued = try await fixture.makeJob(.recovery, "queued-rebind.wav")
        let oldProbe = SuspendedExecutorProbe()
        let oldRunner = LocalJobRunner(store: fixture.store, executor: oldProbe.execute)
        await oldRunner.enqueue(current.id)
        await oldRunner.enqueue(queued.id)
        await oldProbe.waitUntilStarted(current.id)

        let shutdown = Task { await oldRunner.shutdown() }
        await Task.yield()
        await oldProbe.resume(current.id)
        await shutdown.value

        #expect(await oldProbe.started == [current.id])
        #expect(try await fixture.store.job(id: queued.id)?.state == .queued)

        let freshProbe = SuspendedExecutorProbe()
        let freshRunner = LocalJobRunner(store: fixture.store, executor: freshProbe.execute)
        await freshRunner.resumeQueuedJobs()
        await freshProbe.waitUntilStarted(queued.id)
        await freshProbe.resume(queued.id)
        await freshRunner.waitUntilIdle()
        #expect(await freshProbe.started == [queued.id])
    }

    @Test func executesQueuedJobsSeriallyInFIFOOrder() async throws {
        let fixture = try RunnerFixture()
        let first = try await fixture.makeJob(.recovery, "first.wav")
        let second = try await fixture.makeJob(.mediaImport, "second.wav")
        let probe = SuspendedExecutorProbe()
        let runner = LocalJobRunner(store: fixture.store, executor: probe.execute)

        await runner.enqueue(first.id)
        await runner.enqueue(second.id)
        await probe.waitUntilStarted(first.id)

        #expect(await probe.started == [first.id])
        #expect(await probe.maximumConcurrentExecutions == 1)

        await probe.resume(first.id)
        await probe.waitUntilStarted(second.id)
        #expect(await probe.started == [first.id, second.id])
        #expect(await probe.maximumConcurrentExecutions == 1)

        await probe.resume(second.id)
        await runner.waitUntilIdle()
        #expect(try await fixture.store.job(id: first.id)?.state == .ready)
        #expect(try await fixture.store.job(id: second.id)?.state == .ready)
    }

    @Test func separateKindRunnersShareOneSerialExecutionAuthority() async throws {
        let fixture = try RunnerFixture()
        let recovery = try await fixture.makeJob(.recovery, "recovery.wav")
        let media = try await fixture.makeJob(.mediaImport, "media.mov")
        let probe = SuspendedExecutorProbe()
        let authority = LocalJobExecutionAuthority()
        let recoveryRunner = LocalJobRunner(store: fixture.store, kind: .recovery, executionAuthority: authority, executor: probe.execute)
        let mediaRunner = LocalJobRunner(store: fixture.store, kind: .mediaImport, executionAuthority: authority, executor: probe.execute)

        await recoveryRunner.enqueue(recovery.id)
        await mediaRunner.enqueue(media.id)
        await probe.waitUntilStarted(recovery.id)
        #expect(await probe.maximumConcurrentExecutions == 1)
        #expect(await probe.started == [recovery.id])

        await probe.resume(recovery.id)
        await probe.waitUntilStarted(media.id)
        #expect(await probe.maximumConcurrentExecutions == 1)
        await probe.resume(media.id)
        await recoveryRunner.waitUntilIdle()
        await mediaRunner.waitUntilIdle()
        #expect(try await fixture.store.job(id: recovery.id)?.state == .ready)
        #expect(try await fixture.store.job(id: media.id)?.state == .ready)
    }

    @Test func runnerPublishesProcessingAndTerminalChanges() async throws {
        let fixture = try RunnerFixture()
        let job = try await fixture.makeJob(.recovery, "changes.wav")
        let changes = JobChangeProbe()
        let runner = LocalJobRunner(store: fixture.store, didChange: { id in await changes.record(id) }) { _, _ in }

        await runner.enqueue(job.id)
        await runner.waitUntilIdle()

        #expect(await changes.ids == [job.id, job.id])
    }

    @Test func cancellationRemovesQueuedJobBeforeExecution() async throws {
        let fixture = try RunnerFixture()
        let first = try await fixture.makeJob(.recovery, "first.wav")
        let second = try await fixture.makeJob(.recovery, "second.wav")
        let probe = SuspendedExecutorProbe()
        let runner = LocalJobRunner(store: fixture.store, executor: probe.execute)

        await runner.enqueue(first.id)
        await runner.enqueue(second.id)
        await probe.waitUntilStarted(first.id)
        await runner.cancel(second.id)

        #expect(try await fixture.store.job(id: second.id)?.state == .cancelled)
        await probe.resume(first.id)
        await runner.waitUntilIdle()
        #expect(await probe.started == [first.id])
    }

    @Test func cancellationIsObservedCooperativelyByRunningJob() async throws {
        let fixture = try RunnerFixture()
        let job = try await fixture.makeJob(.recovery, "running.wav")
        let probe = SuspendedExecutorProbe()
        let runner = LocalJobRunner(store: fixture.store, executor: probe.execute)

        await runner.enqueue(job.id)
        await probe.waitUntilStarted(job.id)
        let outcome = await runner.cancel(job.id)
        await probe.resume(job.id)
        await runner.waitUntilIdle()

        #expect(outcome == .accepted)
        #expect(try await fixture.store.job(id: job.id)?.state == .cancelled)
    }

    @Test func resumeQueuedJobsConsumesPersistedQueueInStoreOrder() async throws {
        let fixture = try RunnerFixture()
        let first = try await fixture.makeJob(.recovery, "first.wav")
        let second = try await fixture.makeJob(.mediaImport, "second.wav")
        try await fixture.store.transition(first.id, from: .queued, to: .processing(stage: .transcribing))
        let probe = SuspendedExecutorProbe()
        let runner = LocalJobRunner(store: fixture.store, executor: probe.execute)

        await runner.resumeQueuedJobs()
        await probe.waitUntilStarted(first.id)
        await probe.resume(first.id)
        await probe.waitUntilStarted(second.id)
        await probe.resume(second.id)
        await runner.waitUntilIdle()

        #expect(await probe.started == [first.id, second.id])
    }

    @Test func recoveryScopedRunnerIgnoresQueuedMediaImportsAndRejectsTheirEnqueue() async throws {
        let fixture = try RunnerFixture()
        let recovery = try await fixture.makeJob(.recovery, "recovery.wav")
        let media = try await fixture.makeJob(.mediaImport, "media.wav")
        let probe = SuspendedExecutorProbe()
        let runner = LocalJobRunner(store: fixture.store, kind: .recovery, executor: probe.execute)

        await runner.enqueue(media.id)
        await runner.resumeQueuedJobs()
        await probe.waitUntilStarted(recovery.id)
        await probe.resume(recovery.id)
        await runner.waitUntilIdle()

        #expect(await probe.started == [recovery.id])
        #expect(try await fixture.store.job(id: media.id)?.state == .queued)
    }

    @Test func resumeDuringExecutionDoesNotRecoverTheRunningJob() async throws {
        let fixture = try RunnerFixture()
        let current = try await fixture.makeJob(.recovery, "current.wav")
        let follower = try await fixture.makeJob(.mediaImport, "follower.wav")
        let probe = SuspendedExecutorProbe()
        let runner = LocalJobRunner(store: fixture.store, executor: probe.execute)

        await runner.enqueue(current.id)
        await probe.waitUntilStarted(current.id)
        await runner.resumeQueuedJobs()

        #expect(try await fixture.store.job(id: current.id)?.state == .processing(stage: .preparing))
        await probe.resume(current.id)
        await probe.waitUntilStarted(follower.id)
        await probe.resume(follower.id)
        await runner.waitUntilIdle()

        #expect(await probe.started == [current.id, follower.id])
        #expect(try await fixture.store.job(id: current.id)?.state == .ready)
        #expect(try await fixture.store.job(id: follower.id)?.state == .ready)
    }

    @Test func cancellationAfterFinalizationStartsIsTooLate() async throws {
        let fixture = try RunnerFixture()
        let job = try await fixture.makeJob(.recovery, "finalizing.wav")
        let store = SuspendedReadyTransitionStore(base: fixture.store)
        let runner = LocalJobRunner(store: store) { _, token in
            try token.checkCancellation()
        }

        await runner.enqueue(job.id)
        await store.waitUntilReadyTransitionStarts()
        let outcome = await runner.cancel(job.id)

        #expect(outcome == .tooLate)
        await store.resumeReadyTransition()
        await runner.waitUntilIdle()
        #expect(try await fixture.store.job(id: job.id)?.state == .ready)
    }

    @Test func failedDefaultReadyTransitionLeavesJobVisiblyFailed() async throws {
        let fixture = try RunnerFixture()
        let job = try await fixture.makeJob(.recovery, "ready-fails.wav")
        let store = FailingReadyTransitionStore(base: fixture.store)
        let runner = LocalJobRunner(store: store) { _, _ in }

        await runner.enqueue(job.id)
        await runner.waitUntilIdle()

        #expect(try await fixture.store.job(id: job.id)?.state == .failed(
            JobFailure(stage: .preparing, message: "ready transition failed")
        ))
    }

    @Test func cancellationDuringInitialReadPreventsExecutorStart() async throws {
        let fixture = try RunnerFixture()
        let job = try await fixture.makeJob(.recovery, "claimed.wav")
        let store = SuspendedInitialReadStore(base: fixture.store, suspendedID: job.id)
        let probe = SuspendedExecutorProbe()
        let runner = LocalJobRunner(store: store, executor: probe.execute)

        await runner.enqueue(job.id)
        await store.waitUntilInitialReadStarts()
        let outcome = await runner.cancel(job.id)
        await store.resumeInitialRead()
        await runner.waitUntilIdle()

        #expect(outcome == .accepted)
        #expect(await probe.started.isEmpty)
        #expect(try await fixture.store.job(id: job.id)?.state == .cancelled)
    }

    @Test func claimedJobIgnoresDuplicateEnqueueAndResumeDiscovery() async throws {
        let fixture = try RunnerFixture()
        let first = try await fixture.makeJob(.recovery, "first.wav")
        let second = try await fixture.makeJob(.mediaImport, "second.wav")
        let store = SuspendedInitialReadStore(base: fixture.store, suspendedID: first.id)
        let probe = SuspendedExecutorProbe()
        let runner = LocalJobRunner(store: store, executor: probe.execute)

        await runner.enqueue(first.id)
        await store.waitUntilInitialReadStarts()
        await runner.enqueue(first.id)
        await runner.resumeQueuedJobs()
        await store.resumeInitialRead()

        await probe.waitUntilStarted(first.id)
        await probe.resume(first.id)
        await probe.waitUntilStarted(second.id)
        await probe.resume(second.id)
        await runner.waitUntilIdle()

        #expect(await probe.started == [first.id, second.id])
        // Initial validation plus the intentional fresh read after entering processing.
        #expect(await store.readCount(for: first.id) == 2)
    }

    @Test func missingClaimIsReleasedAndDrainContinues() async throws {
        let fixture = try RunnerFixture()
        let follower = try await fixture.makeJob(.recovery, "follower.wav")
        let probe = SuspendedExecutorProbe()
        let runner = LocalJobRunner(store: fixture.store, executor: probe.execute)

        await runner.enqueue(UUID())
        await runner.enqueue(follower.id)
        await probe.waitUntilStarted(follower.id)
        await probe.resume(follower.id)
        await runner.waitUntilIdle()

        #expect(await probe.started == [follower.id])
    }

    @Test func quickRelaunchRechecksAtLeaseExpiryAndResumesExactlyOnce() async throws {
        let database = try TemporaryRunnerDatabase()
        let clock = RunnerMutableClock(Date(timeIntervalSince1970: 100))
        let store = try TranscriptionJobStore(databaseURL: database.url, clock: clock)
        let job = try await store.create(kind: .recovery, source: .init(reference: "recovery.wav"), now: clock.now)
        _ = try await store.claimQueuedJob(job.id, kind: .recovery, owner: UUID(), leaseDuration: 5)
        let sleeper = LeaseSleeperProbe()
        let executor = SuspendedExecutorProbe()
        let runner = LocalJobRunner(store: store, kind: .recovery, leaseSleeper: sleeper.sleep, executor: executor.execute)

        await runner.resumeQueuedJobs()
        await sleeper.waitUntilScheduled()
        #expect(await sleeper.delays == [5])
        clock.advance(by: 6)
        await sleeper.release()
        await executor.waitUntilStarted(job.id)
        #expect(await executor.started == [job.id])
        await executor.resume(job.id)
        await runner.waitUntilIdle()
        #expect(try await store.job(id: job.id)?.state == .ready)
    }

    @Test @MainActor func libraryFacadeRefreshesKindSpecificArrays() async throws {
        let fixture = try RunnerFixture()
        let recovery = try await fixture.makeJob(.recovery, "recovery.wav")
        let mediaImport = try await fixture.makeJob(.mediaImport, "movie.mp4")
        let library = JobLibraryStore(store: fixture.store)

        try await library.refresh()

        #expect(library.recoveryJobs.map(\.id) == [recovery.id])
        #expect(library.importJobs.map(\.id) == [mediaImport.id])
    }

    @Test @MainActor func libraryFacadeRetryRefreshesAndEnqueues() async throws {
        let fixture = try RunnerFixture()
        let job = try await fixture.makeFailedRecovery()
        let enqueued = EnqueueProbe()
        let library = JobLibraryStore(store: fixture.store)
        library.configureRetry { id in await enqueued.record(id) }
        try await library.refresh()

        try await library.retry(id: job.id, configuration: .init(language: "pt"))

        #expect(library.recoveryJobs.first?.state == .queued)
        #expect(await enqueued.ids == [job.id])
        #expect(try await fixture.store.attempts(jobID: job.id).first?.configuration.language == "pt")
    }

    @Test @MainActor func libraryFacadeCaptureAndDeleteRefreshPublishedJobs() async throws {
        let fixture = try RunnerFixture()
        let recoveries = fixture.database.directory.appendingPathComponent("recoveries", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveries, withIntermediateDirectories: true)
        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: recoveries)

        let id = try await library.preserve(samples: [0, 0.25], metadata: .init(capturedAt: Date(), failure: .init(stage: .transcribing, message: "offline")))
        #expect(library.recoveryJobs.map(\.id) == [id])

        try await library.delete(id: id)
        #expect(library.recoveryJobs.isEmpty)
        #expect(try await fixture.store.job(id: id) == nil)
    }

    @Test @MainActor func libraryFacadeSurfacesPlaybackStartFailure() async throws {
        let fixture = try RunnerFixture()
        let job = try await fixture.makeFailedRecovery()
        let library = JobLibraryStore(store: fixture.store, playbackFactory: { _ in PlaybackStub(starts: false) })
        try await library.refresh()

        #expect(throws: RecoveryPlaybackError.couldNotStart) { try library.play(id: job.id) }
    }

    @Test @MainActor func importFacadePreservesEveryCancellationOutcomeAndMessage() async throws {
        for outcome in [LocalJobRunner.CancellationOutcome.accepted, .tooLate, .notRunning] {
            let fixture = try RunnerFixture()
            let job = try await fixture.makeJob(.mediaImport, "movie.mov")
            try await fixture.store.transition(job.id, from: .queued, to: .processing(stage: .finalizing))
            if outcome == .notRunning { try await fixture.store.transition(job.id, from: .processing, to: .ready) }
            let library = JobLibraryStore(store: fixture.store)
            library.configureImports(
                service: MediaImportService(store: fixture.store),
                directory: fixture.database.directory,
                enqueue: { _ in },
                cancel: { _ in outcome }
            )

            let received = try await library.cancelImport(id: job.id)

            #expect(received == outcome)
            #expect(library.importStatusMessage == MediaImportPresentation.cancellationMessage(outcome))
        }
    }

    @Test @MainActor func libraryFacadeRetryAndDeleteRaceHasOneDurableWinner() async throws {
        let fixture = try RunnerFixture()
        let recoveries = fixture.database.directory.appendingPathComponent("recoveries", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveries, withIntermediateDirectories: true)
        let source = recoveries.appendingPathComponent("\(UUID()).wav")
        try Data("audio".utf8).write(to: source)
        let job = try await fixture.makeFailedRecovery(source: source.path)
        let secondStore = try TranscriptionJobStore(databaseURL: fixture.database.url, clock: SystemJobClock())
        let retryLibrary = JobLibraryStore(store: fixture.store, recoveryDirectory: recoveries)
        let deleteLibrary = JobLibraryStore(store: secondStore, recoveryDirectory: recoveries)

        async let retry: Result<Void, Error> = facadeResult { try await retryLibrary.retry(id: job.id, configuration: .init(language: "pt")) }
        async let delete: Result<Void, Error> = facadeResult { try await deleteLibrary.delete(id: job.id) }
        let outcomes = await [retry, delete]
        let persisted = try await fixture.store.job(id: job.id)

        #expect(outcomes.count { if case .success = $0 { true } else { false } } == 1)
        if let persisted {
            #expect(persisted.state == .queued)
            #expect(try await fixture.store.attempts(jobID: job.id).count == 1)
            #expect(FileManager.default.fileExists(atPath: source.path))
        } else {
            #expect(try await fixture.store.attempts(jobID: job.id).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: source.path))
        }
    }
}

private struct RunnerFixture {
    let database: TemporaryRunnerDatabase
    let store: TranscriptionJobStore

    init() throws {
        database = try TemporaryRunnerDatabase()
        store = try TranscriptionJobStore(databaseURL: database.url, clock: SystemJobClock())
    }

    func makeJob(_ kind: JobKind, _ reference: String) async throws -> TranscriptionJob {
        try await store.create(kind: kind, source: JobSource(reference: reference), now: Date())
    }

    func makeFailedRecovery(source: String? = nil) async throws -> TranscriptionJob {
        let job = try await makeJob(.recovery, source ?? database.directory.appendingPathComponent("\(UUID()).wav").path)
        try await store.transition(job.id, from: .queued, to: .processing(stage: .preparing))
        try await store.transition(job.id, from: .processing, to: .failed(.init(stage: .transcribing, message: "offline")))
        return try #require(try await store.job(id: job.id))
    }
}

private func facadeResult(_ operation: () async throws -> Void) async -> Result<Void, Error> {
    do { try await operation(); return .success(()) }
    catch { return .failure(error) }
}

private actor EnqueueProbe {
    private(set) var ids: [UUID] = []
    func record(_ id: UUID) { ids.append(id) }
}

private actor JobChangeProbe {
    private(set) var ids: [UUID] = []
    func record(_ id: UUID) { ids.append(id) }
}

private final class RunnerMutableClock: JobClock, @unchecked Sendable {
    private let lock: NSLock
    private var value: Date
    init(_ value: Date) { self.value = value; lock = NSLock() }
    var now: Date { lock.withLock { value } }
    func advance(by seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

private actor LeaseSleeperProbe {
    private(set) var delays: [TimeInterval] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func sleep(_ delay: TimeInterval) async {
        delays.append(delay)
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilScheduled() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class PlaybackStub: RecoveryAudioPlaying {
    let starts: Bool
    init(starts: Bool) { self.starts = starts }
    func play() -> Bool { starts }
}

private final class TemporaryRunnerDatabase: @unchecked Sendable {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: "jobs.sqlite")
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private actor SuspendedExecutorProbe {
    private(set) var started: [UUID] = []
    private(set) var maximumConcurrentExecutions = 0
    private var active = 0
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    func execute(job: TranscriptionJob, token: CancellationToken) async throws {
        started.append(job.id)
        active += 1
        maximumConcurrentExecutions = max(maximumConcurrentExecutions, active)
        await withCheckedContinuation { continuations[job.id] = $0 }
        active -= 1
        try token.checkCancellation()
    }

    func waitUntilStarted(_ id: UUID) async {
        while !started.contains(id) { await Task.yield() }
    }

    func resume(_ id: UUID) {
        continuations.removeValue(forKey: id)?.resume()
    }
}

private actor SuspendedReadyTransitionStore: TranscriptionJobStoring {
    private let base: TranscriptionJobStore
    private var readyTransitionStarted = false
    private var readyContinuation: CheckedContinuation<Void, Never>?

    init(base: TranscriptionJobStore) {
        self.base = base
    }

    func job(id: UUID) async throws -> TranscriptionJob? {
        try await base.job(id: id)
    }

    func jobs(kind: JobKind?) async throws -> [TranscriptionJob] {
        try await base.jobs(kind: kind)
    }

    func recoverInterruptedJobs(kind: JobKind?) async throws -> Int {
        try await base.recoverInterruptedJobs(kind: kind)
    }

    func transition(_ id: UUID, from: JobState.Kind, to state: JobState) async throws {
        if state == .ready {
            readyTransitionStarted = true
            await withCheckedContinuation { readyContinuation = $0 }
        }
        try await base.transition(id, from: from, to: state)
    }

    func waitUntilReadyTransitionStarts() async {
        while !readyTransitionStarted { await Task.yield() }
    }

    func resumeReadyTransition() {
        readyContinuation?.resume()
        readyContinuation = nil
    }
}

private actor FailingReadyTransitionStore: TranscriptionJobStoring {
    let base: TranscriptionJobStore

    init(base: TranscriptionJobStore) { self.base = base }

    func job(id: UUID) async throws -> TranscriptionJob? { try await base.job(id: id) }
    func jobs(kind: JobKind?) async throws -> [TranscriptionJob] { try await base.jobs(kind: kind) }
    func recoverInterruptedJobs(kind: JobKind?) async throws -> Int { try await base.recoverInterruptedJobs(kind: kind) }
    func transition(_ id: UUID, from: JobState.Kind, to state: JobState) async throws {
        if state == .ready { throw RunnerFinalizationError.ready }
        try await base.transition(id, from: from, to: state)
    }
}

private enum RunnerFinalizationError: LocalizedError {
    case ready
    var errorDescription: String? { "ready transition failed" }
}

private actor SuspendedInitialReadStore: TranscriptionJobStoring {
    private let base: TranscriptionJobStore
    private let suspendedID: UUID
    private var didSuspend = false
    private var readStarted = false
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var readCounts: [UUID: Int] = [:]

    init(base: TranscriptionJobStore, suspendedID: UUID) {
        self.base = base
        self.suspendedID = suspendedID
    }

    func job(id: UUID) async throws -> TranscriptionJob? {
        readCounts[id, default: 0] += 1
        if id == suspendedID, !didSuspend {
            didSuspend = true
            readStarted = true
            await withCheckedContinuation { readContinuation = $0 }
        }
        return try await base.job(id: id)
    }

    func jobs(kind: JobKind?) async throws -> [TranscriptionJob] {
        try await base.jobs(kind: kind)
    }

    func recoverInterruptedJobs(kind: JobKind?) async throws -> Int {
        try await base.recoverInterruptedJobs(kind: kind)
    }

    func transition(_ id: UUID, from: JobState.Kind, to state: JobState) async throws {
        try await base.transition(id, from: from, to: state)
    }

    func waitUntilInitialReadStarts() async {
        while !readStarted { await Task.yield() }
    }

    func resumeInitialRead() {
        readContinuation?.resume()
        readContinuation = nil
    }

    func readCount(for id: UUID) -> Int {
        readCounts[id, default: 0]
    }
}
