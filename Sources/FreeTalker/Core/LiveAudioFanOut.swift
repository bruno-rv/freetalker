import Foundation

/// One bounded, strictly-FIFO, single-consumer audio queue per live-streaming Recording
/// (BRAINSTORM_STREAMING_ASR.md; Codex finding 8). `AudioCapture`'s tap previously fed
/// `streamingEngine.append` through a closure that spawned a fresh unstructured `Task` per
/// buffer — not FIFO-ordered (concurrently-spawned tasks don't preserve arrival order), reenters
/// the engine actor across each `await` inside `append` (two chunks could interleave mid-decode),
/// unbounded (a stalled decoder retains every sample array forever), and had no way to stop a
/// late chunk from a just-ended Recording reaching a later one's engine state. This queue is
/// created fresh per Recording and `finish()`ed the moment that Recording's live session ends —
/// enqueueing after `finish()` is a no-op (`AsyncStream` drops further `yield`s), so a stale
/// fan-out can never deliver into a different Recording's `streamingEngine` state.
final class LiveAudioFanOut: @unchecked Sendable {
    /// Perceived-latency audio arrives in small (100-200ms) chunks; a stalled decoder should
    /// disable streaming for this Recording, not buffer an unbounded backlog.
    // ponytail: fixed cap, raise if real-world overflow telemetry shows it's too tight.
    static let capacity = 32

    private let stream: AsyncStream<[Float]>
    private let continuation: AsyncStream<[Float]>.Continuation
    private var consumerTask: Task<Void, Never>?
    private let overflowLock = NSLock()
    private var overflowReported = false

    init() {
        var continuation: AsyncStream<[Float]>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .bufferingNewest(Self.capacity)) { continuation = $0 }
        self.continuation = continuation
    }

    /// Synchronous, allocation-light enqueue — called directly from `AudioCapture`'s tap
    /// callback (an arbitrary audio thread), never spawns a `Task` on the steady-state path.
    /// `onOverflow` fires at most once, the first time a chunk is dropped for exceeding
    /// `capacity`; callers hop to `@MainActor` inside it themselves.
    func enqueue(_ samples: [Float], onOverflow: @escaping @Sendable () -> Void) {
        guard case .dropped = continuation.yield(samples) else { return }
        let shouldReport = overflowLock.withLock {
            guard !overflowReported else { return false }
            overflowReported = true
            return true
        }
        if shouldReport { onOverflow() }
    }

    /// Starts the single consumer that drains the queue strictly in order — each chunk is fully
    /// `await`ed by `consume` before the next is even dequeued, which is what makes ordering FIFO
    /// and prevents actor reentrancy from interleaving two chunks' decode work.
    func start(consume: @escaping @Sendable ([Float]) async -> Void) {
        let stream = self.stream
        consumerTask = Task {
            for await samples in stream {
                await consume(samples)
            }
        }
    }

    /// Ends the queue and cancels the consumer. Any `enqueue` after this point is a no-op.
    /// Returns the consumer's `Task` (Codex finding 3) so the caller can `await` its actual
    /// completion before reusing the shared engine: `cancel()` alone is cooperative and does NOT
    /// stop a chunk that's already `await`ing inside `consume` (e.g. a suspended CoreML
    /// prediction) — without joining that Task first, a later capture's `setPartialCallback` can
    /// install its own handoff on the SAME shared engine while this stale chunk is still in
    /// flight, and the engine can end up delivering this chunk's decoded tokens through the
    /// later capture's live callback.
    @discardableResult
    func finish() -> Task<Void, Never>? {
        continuation.finish()
        consumerTask?.cancel()
        let task = consumerTask
        consumerTask = nil
        return task
    }
}
