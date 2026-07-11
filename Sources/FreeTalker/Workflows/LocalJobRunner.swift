import Foundation

protocol TranscriptionJobStoring: Sendable {
    func job(id: UUID) async throws -> TranscriptionJob?
    func jobs(kind: JobKind?) async throws -> [TranscriptionJob]
    func transition(_ id: UUID, from: JobState.Kind, to state: JobState) async throws
    func recoverInterruptedJobs() async throws -> Int
}

extension TranscriptionJobStore: TranscriptionJobStoring {}

final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
    }

    func checkCancellation() throws {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled { throw CancellationError() }
    }
}

actor LocalJobRunner {
    typealias Executor = @Sendable (TranscriptionJob, CancellationToken) async throws -> Void

    enum CancellationOutcome: Sendable, Equatable {
        case accepted
        case tooLate
        case notRunning
    }

    private enum ExecutionPhase {
        case executing
        case finalizing
    }

    private struct CurrentExecution {
        let id: UUID
        let token: CancellationToken
        var phase: ExecutionPhase
    }

    private let store: any TranscriptionJobStoring
    private let executor: Executor
    private var queue: [UUID] = []
    private var worker: Task<Void, Never>?
    private var current: CurrentExecution?

    init(store: any TranscriptionJobStoring, executor: @escaping Executor) {
        self.store = store
        self.executor = executor
    }

    func enqueue(_ id: UUID) {
        guard current?.id != id, !queue.contains(id) else { return }
        queue.append(id)
        startWorkerIfNeeded()
    }

    /// Cancellation is accepted through executor completion. Once finalization starts,
    /// completion owns the terminal state and cancellation is reported as too late.
    @discardableResult
    func cancel(_ id: UUID) async -> CancellationOutcome {
        if let current, current.id == id {
            guard current.phase == .executing else { return .tooLate }
            current.token.cancel()
            return .accepted
        }

        guard queue.contains(id) else { return .notRunning }
        queue.removeAll { $0 == id }
        try? await store.transition(id, from: .queued, to: .cancelled)
        return .accepted
    }

    func resumeQueuedJobs() async {
        if worker == nil, current == nil {
            _ = try? await store.recoverInterruptedJobs()
        }
        guard let jobs = try? await store.jobs(kind: nil) else { return }
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
            let token = CancellationToken()
            current = CurrentExecution(id: id, token: token, phase: .executing)
            await execute(id, token: token)
            current = nil
        }
        worker = nil
    }

    private func execute(_ id: UUID, token: CancellationToken) async {
        guard let job = try? await store.job(id: id), job.state == .queued else { return }

        do {
            try await store.transition(id, from: .queued, to: .processing(stage: .preparing))
        } catch {
            return
        }

        do {
            try token.checkCancellation()
            let currentJob = try await store.job(id: id) ?? job
            try await executor(currentJob, token)
            try token.checkCancellation()
            current?.phase = .finalizing
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
