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
/// and never starts the expensive work. `nonisolated(unsafe)` for the same reason
/// `TranscribeFileCommand`/`CleanUpTextCommand` already use it elsewhere in this feature: the
/// Apple Event Manager serializes command dispatch on the main thread, so this plain
/// check-then-set has no concurrent writer to race with.
enum AutomationConcurrencyGate {
    nonisolated(unsafe) private static var cleanUpInFlight = false
    nonisolated(unsafe) private static var transcribeInFlight = false

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

    /// Same contract as `beginCleanUp()`/`endCleanUp()`, for `transcribe` — Codex round-2
    /// Finding 4. A separate slot from `clean up`'s: the two commands have different resource
    /// profiles (import queue + WhisperKit vs. on-device prompt processing) and neither needing to
    /// wait on the other's slot is strictly more permissive without reopening either finding.
    static func beginTranscribe() -> Bool {
        guard !transcribeInFlight else { return false }
        transcribeInFlight = true
        return true
    }

    static func endTranscribe() {
        transcribeInFlight = false
    }
}
