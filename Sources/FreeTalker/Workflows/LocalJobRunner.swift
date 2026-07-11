import Foundation

actor CancellationToken {
    private var isCancelled = false

    func cancel() {
        isCancelled = true
    }

    func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }
}

actor LocalJobRunner {
    typealias Executor = @Sendable (TranscriptionJob, CancellationToken) async throws -> Void

    private let store: TranscriptionJobStore
    private let executor: Executor
    private var queue: [UUID] = []
    private var worker: Task<Void, Never>?
    private var current: (id: UUID, token: CancellationToken)?

    init(store: TranscriptionJobStore, executor: @escaping Executor) {
        self.store = store
        self.executor = executor
    }

    func enqueue(_ id: UUID) {
        guard current?.id != id, !queue.contains(id) else { return }
        queue.append(id)
        startWorkerIfNeeded()
    }

    func cancel(_ id: UUID) async {
        if current?.id == id, let token = current?.token {
            await token.cancel()
            return
        }

        guard queue.contains(id) else { return }
        queue.removeAll { $0 == id }
        try? await store.transition(id, from: .queued, to: .cancelled)
    }

    func resumeQueuedJobs() async {
        _ = try? await store.recoverInterruptedJobs()
        guard let jobs = try? await store.jobs() else { return }
        for job in jobs where job.state == .queued {
            if current?.id != job.id, !queue.contains(job.id) {
                queue.append(job.id)
            }
        }
        startWorkerIfNeeded()
    }

    func waitUntilIdle() async {
        while worker != nil { await Task.yield() }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { await self.drainQueue() }
    }

    private func drainQueue() async {
        while !queue.isEmpty {
            let id = queue.removeFirst()
            await execute(id)
        }
        worker = nil
    }

    private func execute(_ id: UUID) async {
        guard let job = try? await store.job(id: id), job.state == .queued else { return }

        let token = CancellationToken()
        current = (id, token)
        defer { current = nil }

        do {
            try await store.transition(id, from: .queued, to: .processing(stage: .preparing))
        } catch {
            return
        }

        do {
            try await token.checkCancellation()
            let currentJob = try await store.job(id: id) ?? job
            try await executor(currentJob, token)
            try await token.checkCancellation()
            try await store.transition(id, from: .processing, to: .ready)
        } catch is CancellationError {
            try? await store.transition(id, from: .processing, to: .cancelled)
        } catch {
            let stage = try? await store.job(id: id)?.state.processingStage
            let failure = JobFailure(stage: stage ?? .preparing, message: error.localizedDescription)
            try? await store.transition(id, from: .processing, to: .failed(failure))
        }
    }
}

private extension JobState {
    var processingStage: JobStage? {
        guard case .processing(let stage) = self else { return nil }
        return stage
    }
}
