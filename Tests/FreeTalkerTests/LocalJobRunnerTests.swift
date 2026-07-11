import Foundation
import Testing
@testable import FreeTalker

@Suite struct LocalJobRunnerTests {
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

    @Test @MainActor func libraryFacadeRefreshesKindSpecificArrays() async throws {
        let fixture = try RunnerFixture()
        let recovery = try await fixture.makeJob(.recovery, "recovery.wav")
        let mediaImport = try await fixture.makeJob(.mediaImport, "movie.mp4")
        let library = JobLibraryStore(store: fixture.store)

        try await library.refresh()

        #expect(library.recoveryJobs.map(\.id) == [recovery.id])
        #expect(library.importJobs.map(\.id) == [mediaImport.id])
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

    func recoverInterruptedJobs() async throws -> Int {
        try await base.recoverInterruptedJobs()
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

    func recoverInterruptedJobs() async throws -> Int {
        try await base.recoverInterruptedJobs()
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
