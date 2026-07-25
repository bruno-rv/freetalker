import ApplicationServices
import Foundation

/// Correction Loop signal C (BRAINSTORM_CORRECTION_LOOP.md), OFF by default
/// (`AppSettings.correctionLoopEditWatcherEnabled`): for a bounded window after an insertion,
/// polls the SAME AX element `RecentInsertionStore` already verified and offers to remember a
/// single anchored-word edit — never applies one automatically. Reuses `Insertion.
/// streamingSafeElement` (fresh identity/security check before every read) and `Insertion.
/// rangeLimitedEditedReplacement` (a length-only + single bounded parameterized read, confined
/// strictly to the app's own inserted range — see Codex finding 4) plus `CorrectionRecorder.
/// candidate` (the same anchored-substitution diff every signal uses) — no parallel detection
/// logic. Any AX read failure (an app that exposes text badly — Electron, most web views) stops
/// watching THIS insertion outright (Codex finding 12) rather than silently retrying it for the
/// rest of the window; it never surfaces as broken.
@MainActor
final class EditWatcher {
    static let shared = EditWatcher()
    private init() {}

    static let pollInterval: TimeInterval = 2
    /// Deliberately shorter than `RecentInsertionStore.window` — signal C is the riskiest of the
    /// three (the only one reading text the user didn't explicitly hand over), so it gets the
    /// tightest bound. Enforced as a plain elapsed-poll-count budget (Codex finding 12) — never
    /// `Date()` — so wall-clock rollback/adjustment can't extend it.
    static let window: TimeInterval = 90

    private var task: Task<Void, Never>?

    /// Called once per successful insertion (see `AppCoordinator`'s wiring, right where
    /// `RecentInsertionStore` gets its dictation id attached). A no-op unless the setting is on.
    /// Cancels any watcher still running for a PRIOR insertion first — only ever one insertion is
    /// watched at a time, matching "the most recent dictation" everywhere else in this feature.
    func beginWatching(dictationID: Int64) {
        task?.cancel()
        task = nil
        guard AppSettings.shared.correctionLoopEditWatcherEnabled else { return }
        task = Task { [weak self] in
            var elapsed: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
                elapsed += Self.pollInterval
                guard !Task.isCancelled else { return }
                // Codex finding 12: re-checked after EVERY sleep, not just once at the start —
                // turning the setting off mid-window must stop the watcher immediately, and the
                // deadline is re-evaluated AFTER sleeping (not just before), so a poll that starts
                // just under the deadline can't still run one more cycle past it.
                guard Self.shouldContinuePolling(
                    elapsed: elapsed, window: Self.window,
                    settingEnabled: AppSettings.shared.correctionLoopEditWatcherEnabled
                ) else {
                    self?.stopWatching()
                    return
                }
                guard let self, self.checkOnce(dictationID: dictationID) else { return }
            }
        }
    }

    func stopWatching() {
        task?.cancel()
        task = nil
    }

    /// Pure decision (Codex finding 12), factored out of `beginWatching`'s `Task` loop so the
    /// monotonic-deadline/setting-re-check logic is directly unit-testable without a live
    /// AX/Task environment — same style as `Insertion.shouldSynthesizePaste`. `elapsed` is a plain
    /// accumulated-sleep counter, never `Date()`, so it's immune to wall-clock rollback/adjustment
    /// extending the window.
    nonisolated static func shouldContinuePolling(elapsed: TimeInterval, window: TimeInterval, settingEnabled: Bool) -> Bool {
        settingEnabled && elapsed < window
    }

    /// One poll. Returns whether the watcher should keep polling — `false` on anything that
    /// should stop it outright (dictation superseded, unsafe/unreadable target, or a correction
    /// was just offered), matching `stopWatching()` already having been called by every `false`
    /// path (Codex finding 12: a read failure previously just `return`ed for that tick, silently
    /// retrying an unsafe/unreadable target for the rest of the window despite this type's own
    /// doc comment already claiming otherwise).
    @discardableResult
    private func checkOnce(dictationID: Int64) -> Bool {
        guard let recent = RecentInsertionStore.shared.recent(), recent.dictationID == dictationID else {
            stopWatching()
            return false
        }
        guard let element = Insertion.streamingSafeElement(target: recent.target) else {
            stopWatching()
            return false
        }
        guard let replacement = Insertion.rangeLimitedEditedReplacement(
            element: element, baseline: Array(recent.baselineValue.utf16),
            ledgerLength: recent.text.utf16.count, anchor: recent.anchor
        ) else {
            stopWatching()
            return false
        }
        let observed = String(utf16CodeUnits: replacement, count: replacement.count)
        guard observed != recent.text else { return true }
        guard CorrectionRecorder.candidate(wrongText: recent.text, rightText: observed) != nil else { return true }
        stopWatching()
        CorrectionPanelController.shared.openForObservedEdit(dictationID: dictationID, after: observed)
        return false
    }
}
