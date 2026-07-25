import Foundation

/// Codex round-1 Finding 3 (HIGH, unbounded concurrent work): "Suspended Cocoa commands are
/// explicitly reentrant, so many multi-megabyte payloads become concurrent prompt construction,
/// network calls and memory pressure." Exactly one `clean up` call may be in flight at a time;
/// every other concurrent call is rejected as busy.
///
/// Checked synchronously in `CleanUpTextCommand.performDefaultImplementation()`, BEFORE
/// `suspendExecution()` — a rejected call never suspends, and never starts the expensive work.
/// `nonisolated(unsafe)` for the same reason `TranscribeFileCommand`/`CleanUpTextCommand` already
/// use it elsewhere in this feature: the Apple Event Manager serializes command dispatch on the
/// main thread, so this plain check-then-set has no concurrent writer to race with.
enum AutomationConcurrencyGate {
    nonisolated(unsafe) private static var cleanUpInFlight = false

    /// Returns `true` and claims the single slot if it was free; returns `false` (claims nothing)
    /// if a `clean up` is already running. Callers that get `true` MUST call `endCleanUp()` when
    /// the request finishes, success or failure.
    static func beginCleanUp() -> Bool {
        guard !cleanUpInFlight else { return false }
        cleanUpInFlight = true
        return true
    }

    static func endCleanUp() {
        cleanUpInFlight = false
    }
}
