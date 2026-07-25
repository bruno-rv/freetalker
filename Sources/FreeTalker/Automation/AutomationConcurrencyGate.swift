import Foundation

/// Codex round-1 Finding 3 (HIGH, unbounded concurrent work): "Suspended Cocoa commands are
/// explicitly reentrant, so many multi-megabyte payloads become concurrent prompt construction,
/// network calls and memory pressure." Exactly one `clean up` call may be in flight at a time;
/// every other concurrent call is rejected as busy.
///
/// Codex round-2 Finding 4 (HIGH): the round-1 gate only covered `clean up` — `transcribe`
/// suspended with no admission control at all, so parallel senders could submit the same
/// authorized file repeatedly, creating unbounded durable import jobs and a 200 ms polling task
/// each, overloading the import queue and keeping the shared transcription engine busy against
/// ordinary dictation. `transcribe` gets its own single-in-flight slot below, claimed and released
/// exactly the same way `clean up`'s is.
///
/// Checked synchronously in `CleanUpTextCommand`/`TranscribeFileCommand`'s
/// `performDefaultImplementation()`, BEFORE `suspendExecution()` — a rejected call never suspends,
/// and never starts the expensive work.
///
/// Codex round-3 additional finding: the OLD reasoning for `nonisolated(unsafe)` with no lock —
/// "the Apple Event Manager serializes command dispatch on the main thread, so this plain
/// check-then-set has no concurrent writer to race with" — covered `beginCleanUp`/`beginTranscribe`
/// (called synchronously from `performDefaultImplementation()`, on the Apple Event Manager's main
/// thread) but NOT `endCleanUp`/`endTranscribe`: those used to run inside each command's `Task {
/// defer { ... } }`, whose body executes off `@MainActor` for parts of its lifetime (see
/// `AutomationService.authorizeStageAndTranscribe`) — a real cross-executor race against a new
/// incoming Apple Event's `beginTranscribe()` on the main thread. A lock removes the need to
/// reason about which caller runs on which thread at all.
enum AutomationConcurrencyGate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cleanUpInFlight = false
    nonisolated(unsafe) private static var transcribeInFlight = false

    /// Returns `true` and claims the single slot if it was free; returns `false` (claims nothing)
    /// if a `clean up` is already running. Callers that get `true` MUST call `endCleanUp()` when
    /// the request finishes, success or failure — and, per the additional finding above, BEFORE
    /// resuming the Apple Event reply, never after (see `CleanUpTextCommand`).
    static func beginCleanUp() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cleanUpInFlight else { return false }
        cleanUpInFlight = true
        return true
    }

    static func endCleanUp() {
        lock.lock(); defer { lock.unlock() }
        cleanUpInFlight = false
    }

    /// Same contract as `beginCleanUp()`/`endCleanUp()`, for `transcribe` — Codex round-2
    /// Finding 4. A separate slot from `clean up`'s: the two commands have different resource
    /// profiles (import queue + WhisperKit vs. on-device prompt processing) and neither needing to
    /// wait on the other's slot is strictly more permissive without reopening either finding.
    static func beginTranscribe() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !transcribeInFlight else { return false }
        transcribeInFlight = true
        return true
    }

    static func endTranscribe() {
        lock.lock(); defer { lock.unlock() }
        transcribeInFlight = false
    }
}
