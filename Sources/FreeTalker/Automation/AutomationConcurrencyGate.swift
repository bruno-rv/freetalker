import Foundation

/// Codex round-1 Finding 3 (HIGH, unbounded concurrent work): "Suspended Cocoa commands are
/// explicitly reentrant, so many multi-megabyte payloads become concurrent prompt construction,
/// network calls and memory pressure." Exactly one `clean up` call may be in flight at a time;
/// every other concurrent call is rejected as busy.
///
/// Checked synchronously in `CleanUpTextCommand`'s `performDefaultImplementation()`, BEFORE
/// `suspendExecution()` — a rejected call never suspends, and never starts the expensive work.
///
/// Codex round-3 additional finding: the OLD reasoning for `nonisolated(unsafe)` with no lock —
/// "the Apple Event Manager serializes command dispatch on the main thread, so this plain
/// check-then-set has no concurrent writer to race with" — covered `beginCleanUp` (called
/// synchronously from `performDefaultImplementation()`, on the Apple Event Manager's main thread)
/// but NOT `endCleanUp`: that used to run inside `CleanUpTextCommand`'s `Task { defer { ... } }`,
/// whose body can execute off `@MainActor` — a real cross-executor race against a new incoming
/// Apple Event's `beginCleanUp()` on the main thread. A lock removes the need to reason about
/// which caller runs on which thread at all.
enum AutomationConcurrencyGate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cleanUpInFlight = false

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
}
