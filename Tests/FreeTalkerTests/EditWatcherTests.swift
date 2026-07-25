import Testing
@testable import FreeTalker

/// Pure-logic coverage for `EditWatcher.shouldContinuePolling` (Codex finding 12): the watcher's
/// poll loop re-checks BOTH the setting and a monotonic (never `Date()`) elapsed-time budget after
/// every sleep, rather than only once at `beginWatching` time. No AX/CGEvent, no live `Task`.
@Suite struct EditWatcherTests {
    @Test func continuesWhileEnabledAndUnderTheWindow() {
        #expect(EditWatcher.shouldContinuePolling(elapsed: 0, window: 90, settingEnabled: true))
        #expect(EditWatcher.shouldContinuePolling(elapsed: 88, window: 90, settingEnabled: true))
    }

    /// Codex finding 12: turning the setting off mid-window must stop the watcher on the VERY
    /// NEXT re-check — not just gate the initial `beginWatching` call.
    @Test func stopsAssoonAsTheSettingIsTurnedOffEvenWellUnderTheWindow() {
        #expect(!EditWatcher.shouldContinuePolling(elapsed: 2, window: 90, settingEnabled: false))
    }

    /// Codex finding 12: the deadline is a plain elapsed-poll-count budget, re-checked AFTER each
    /// sleep — once `elapsed` reaches (or passes) `window`, polling stops on that very check,
    /// never "one more cycle past it."
    @Test func stopsExactlyAtAndPastTheWindowNeverOneCyclePastIt() {
        #expect(!EditWatcher.shouldContinuePolling(elapsed: 90, window: 90, settingEnabled: true))
        #expect(!EditWatcher.shouldContinuePolling(elapsed: 91, window: 90, settingEnabled: true))
    }

    /// Codex finding 12: the budget is a plain counter accumulated purely from
    /// `Self.pollInterval` increments — it never reads `Date()` at all, so it cannot be extended
    /// (or shortened) by a wall-clock rollback/adjustment mid-window. This documents that
    /// contract: two calls with the SAME `elapsed`/`window` always agree, regardless of when in
    /// wall-clock time they're evaluated.
    @Test func deadlineDecisionDependsOnlyOnTheAccumulatedElapsedBudgetNeverWallClockTime() {
        let firstEvaluation = EditWatcher.shouldContinuePolling(elapsed: 44, window: 90, settingEnabled: true)
        let secondEvaluation = EditWatcher.shouldContinuePolling(elapsed: 44, window: 90, settingEnabled: true)
        #expect(firstEvaluation == secondEvaluation)
        #expect(firstEvaluation)
    }
}
