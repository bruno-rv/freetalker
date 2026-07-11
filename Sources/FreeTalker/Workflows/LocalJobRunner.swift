import Foundation

protocol TranscriptionJobStoring: Sendable {
    func job(id: UUID) async throws -> TranscriptionJob?
    func jobs(kind: JobKind?) async throws -> [TranscriptionJob]
    func transition(_ id: UUID, from: JobState.Kind, to state: JobState) async throws
    func recoverInterruptedJobs(kind: JobKind?) async throws -> Int
}

protocol LeasedTranscriptionJobStoring: TranscriptionJobStoring {
    func claimQueuedJob(_ id: UUID, kind: JobKind?, owner: UUID, leaseDuration: TimeInterval) async throws -> TranscriptionJob
    func renewLease(_ id: UUID, owner: UUID, leaseDuration: TimeInterval) async throws
    func transitionOwned(_ id: UUID, owner: UUID, to state: JobState) async throws
    func recoverStaleJobs(kind: JobKind?) async throws -> Int
}

extension TranscriptionJobStore: TranscriptionJobStoring {}

actor LocalJobExecutionAuthority {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        guard occupied else { occupied = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().resume() }
    }
}

final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var finalization: (@Sendable () async throws -> Void)?
    private var leaseOwner: UUID?

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

    func installLeaseOwner(_ owner: UUID) { lock.withLock { leaseOwner = owner } }
    var owner: UUID? { lock.withLock { leaseOwner } }

    func beginFinalization() async throws {
        let operation = lock.withLock { finalization }
        if let operation { try await operation() } else { try checkCancellation() }
    }
}

actor LocalJobRunner {
    typealias Executor = @Sendable (TranscriptionJob, CancellationToken) async throws -> Void
    typealias FinalizationFailure = @Sendable (UUID, UUID?, any Error) async throws -> Void
    typealias DidChange = @Sendable (UUID) async -> Void

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
    private let finalizationFailure: FinalizationFailure?
    private let didChange: DidChange?
    private let leaseDuration: TimeInterval
    private let executionAuthority: LocalJobExecutionAuthority?
    private var queue: [UUID] = []
    private var worker: Task<Void, Never>?
    private var current: CurrentExecution?

    init(
        store: any TranscriptionJobStoring,
        kind: JobKind? = nil,
        executorFinalizesJob: Bool = false,
        finalizationFailure: FinalizationFailure? = nil,
        didChange: DidChange? = nil,
        leaseDuration: TimeInterval = 30,
        executionAuthority: LocalJobExecutionAuthority? = nil,
        executor: @escaping Executor
    ) {
        self.store = store
        self.kind = kind
        self.executorFinalizesJob = executorFinalizesJob
        self.finalizationFailure = finalizationFailure
        self.didChange = didChange
        self.leaseDuration = leaseDuration
        self.executionAuthority = executionAuthority
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
        await didChange?(id)
        return .accepted
    }

    func resumeQueuedJobs() async {
        if worker == nil, current == nil {
            if let leased = store as? any LeasedTranscriptionJobStoring {
                _ = try? await leased.recoverStaleJobs(kind: kind)
            } else {
                _ = try? await store.recoverInterruptedJobs(kind: kind)
            }
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
            token.installLeaseOwner(UUID())
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
            if let leased = store as? any LeasedTranscriptionJobStoring, let owner = token.owner {
                _ = try await leased.claimQueuedJob(id, kind: kind, owner: owner, leaseDuration: leaseDuration)
            } else {
                try await store.transition(id, from: .queued, to: .processing(stage: .preparing))
            }
        } catch {
            return
        }
        await didChange?(id)

        let heartbeat: Task<Void, Never>? = if let leased = store as? any LeasedTranscriptionJobStoring,
                                               let owner = token.owner {
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(max(0.25, leaseDuration / 3)))
                    guard !Task.isCancelled else { return }
                    do { try await leased.renewLease(id, owner: owner, leaseDuration: leaseDuration) }
                    catch { token.cancel(); return }
                }
            }
        } else { nil }
        defer { heartbeat?.cancel() }

        do {
            try token.checkCancellation()
            let currentJob = try await store.job(id: id) ?? job
            if let executionAuthority {
                try await executionAuthority.run { try await executor(currentJob, token) }
            } else {
                try await executor(currentJob, token)
            }
            if !executorFinalizesJob { try await token.beginFinalization() }
            if !executorFinalizesJob {
                try await transitionTerminal(id, token: token, state: .ready)
            }
        } catch is CancellationError {
            try? await transitionTerminal(id, token: token, state: .cancelled)
        } catch {
            if current?.phase == .finalizing {
                await handleFinalizationFailure(id: id, error: error)
                await didChange?(id)
                return
            }
            let stage = try? await store.job(id: id)?.state.processingStage
            let failure = JobFailure(stage: stage ?? .preparing, message: error.localizedDescription)
            try? await transitionTerminal(id, token: token, state: .failed(failure))
        }
        await didChange?(id)
    }

    private func handleFinalizationFailure(id: UUID, error: any Error) async {
        guard let job = try? await store.job(id: id) else { return }
        switch job.state {
        case .ready, .failed, .cancelled:
            return
        case .queued:
            return
        case .processing(let stage):
            if let finalizationFailure {
                try? await finalizationFailure(id, current?.token.owner, error)
                if let refreshed = try? await store.job(id: id),
                   refreshed.state.kind != .processing {
                    return
                }
            }
            let failure = JobFailure(stage: stage, message: error.localizedDescription)
            if let leased = store as? any LeasedTranscriptionJobStoring, let owner = current?.token.owner {
                try? await leased.transitionOwned(id, owner: owner, to: .failed(failure))
            } else {
                try? await store.transition(id, from: .processing, to: .failed(failure))
            }
        }
    }

    private func transitionTerminal(_ id: UUID, token: CancellationToken, state: JobState) async throws {
        if let leased = store as? any LeasedTranscriptionJobStoring, let owner = token.owner {
            try await leased.transitionOwned(id, owner: owner, to: state)
        } else {
            try await store.transition(id, from: .processing, to: state)
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
