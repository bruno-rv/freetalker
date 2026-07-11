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
        await runner.cancel(job.id)
        await probe.resume(job.id)
        await runner.waitUntilIdle()

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
        try await token.checkCancellation()
    }

    func waitUntilStarted(_ id: UUID) async {
        while !started.contains(id) { await Task.yield() }
    }

    func resume(_ id: UUID) {
        continuations.removeValue(forKey: id)?.resume()
    }
}
