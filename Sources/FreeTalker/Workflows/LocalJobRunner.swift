import Foundation

protocol TranscriptionJobStoring: Sendable {
    func job(id: UUID) async throws -> TranscriptionJob?
    func jobs(kind: JobKind?) async throws -> [TranscriptionJob]
    func transition(_ id: UUID, from: JobState.Kind, to state: JobState) async throws
    func recoverInterruptedJobs(kind: JobKind?) async throws -> Int
}

extension TranscriptionJobStore: TranscriptionJobStoring {}

final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var finalization: (@Sendable () async throws -> Void)?

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

    func installFinalization(_ operation: @escaping @Sendable () async throws -> Void) {
        lock.withLock { finalization = operation }
    }

    func beginFinalization() async throws {
        let operation = lock.withLock { finalization }
        if let operation { try await operation() } else { try checkCancellation() }
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
    private let executorFinalizesJob: Bool
    private let kind: JobKind?
    private var queue: [UUID] = []
    private var worker: Task<Void, Never>?
    private var current: CurrentExecution?

    init(
        store: any TranscriptionJobStoring,
        kind: JobKind? = nil,
        executorFinalizesJob: Bool = false,
        executor: @escaping Executor
    ) {
        self.store = store
        self.kind = kind
        self.executorFinalizesJob = executorFinalizesJob
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
            _ = try? await store.recoverInterruptedJobs(kind: kind)
        }
        guard let jobs = try? await store.jobs(kind: kind) else { return }
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
            token.installFinalization { [weak self, weak token] in
                guard let self, let token else { throw CancellationError() }
                try await self.beginFinalization(id: id, token: token)
            }
            current = CurrentExecution(id: id, token: token, phase: .executing)
            await execute(id, token: token)
            current = nil
        }
        worker = nil
    }

    private func execute(_ id: UUID, token: CancellationToken) async {
        guard let job = try? await store.job(id: id), job.state == .queued,
              kind == nil || job.kind == kind else { return }

        do {
            try await store.transition(id, from: .queued, to: .processing(stage: .preparing))
        } catch {
            return
        }

        do {
            try token.checkCancellation()
            let currentJob = try await store.job(id: id) ?? job
            try await executor(currentJob, token)
            if !executorFinalizesJob { try await token.beginFinalization() }
            if !executorFinalizesJob {
                try await store.transition(id, from: .processing, to: .ready)
            }
        } catch is CancellationError {
            try? await store.transition(id, from: .processing, to: .cancelled)
        } catch {
            if current?.phase == .finalizing { return }
            let stage = try? await store.job(id: id)?.state.processingStage
            let failure = JobFailure(stage: stage ?? .preparing, message: error.localizedDescription)
            try? await store.transition(id, from: .processing, to: .failed(failure))
        }
    }

    private func beginFinalization(id: UUID, token: CancellationToken) throws {
        guard let current, current.id == id, current.token === token,
              current.phase == .executing else { throw CancellationError() }
        try token.checkCancellation()
        self.current?.phase = .finalizing
    }
}

private extension JobState {
    var processingStage: JobStage? {
        guard case .processing(let stage) = self else { return nil }
        return stage
    }
}
