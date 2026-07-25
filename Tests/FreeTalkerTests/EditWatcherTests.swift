import Testing
@testable import FreeTalker

/// Pure-logic coverage for `EditWatcher.shouldContinuePolling` (Codex finding 12, deadline shape
/// fixed by Codex Round 2 finding 6): the watcher's poll loop re-checks BOTH the setting and a
/// monotonic `ContinuousClock` deadline after every sleep, rather than only once at
/// `beginWatching` time. No AX/CGEvent, no live `Task`.
@Suite struct EditWatcherTests {
    private static let start = ContinuousClock.now
    private static let deadline = start.advanced(by: .seconds(90))

    @Test func continuesWhileEnabledAndUnderTheWindow() {
        #expect(EditWatcher.shouldContinuePolling(now: Self.start, deadline: Self.deadline, settingEnabled: true))
        #expect(EditWatcher.shouldContinuePolling(now: Self.start.advanced(by: .seconds(88)), deadline: Self.deadline, settingEnabled: true))
    }

    /// Codex finding 12: turning the setting off mid-window must stop the watcher on the VERY
    /// NEXT re-check — not just gate the initial `beginWatching` call.
    @Test func stopsAssoonAsTheSettingIsTurnedOffEvenWellUnderTheWindow() {
        #expect(!EditWatcher.shouldContinuePolling(now: Self.start.advanced(by: .seconds(2)), deadline: Self.deadline, settingEnabled: false))
    }

    /// Codex finding 12: the deadline is re-checked AFTER each sleep — once `now` reaches (or
    /// passes) `deadline`, polling stops on that very check, never "one more cycle past it."
    @Test func stopsExactlyAtAndPastTheWindowNeverOneCyclePastIt() {
        #expect(!EditWatcher.shouldContinuePolling(now: Self.deadline, deadline: Self.deadline, settingEnabled: true))
        #expect(!EditWatcher.shouldContinuePolling(now: Self.start.advanced(by: .seconds(91)), deadline: Self.deadline, settingEnabled: true))
    }

    /// Codex Round 2 finding 6: unlike a plain accumulated-poll counter (which only ever advanced
    /// by exactly `pollInterval` per resumed iteration, no matter how long the actual suspension
    /// was), a `ContinuousClock` deadline correctly reflects a long real-world gap between polls —
    /// e.g. the Mac sleeping for several minutes between two consecutive `Task.sleep` resumptions.
    /// Simulated here by a `now` far past `deadline` despite only ONE poll interval's worth of
    /// logical progress having been made.
    @Test func aLongRealWorldGapBetweenPollsIsNotUndercountedTheWayAPollCounterWouldMiss() {
        let simulatedSleepGap = Self.start.advanced(by: .seconds(600)) // 10 real minutes, one poll
        #expect(!EditWatcher.shouldContinuePolling(now: simulatedSleepGap, deadline: Self.deadline, settingEnabled: true))
    }

    /// The deadline decision depends only on the two `ContinuousClock.Instant`s compared, not on
    /// anything else ambient — two calls with the same inputs always agree.
    @Test func deadlineDecisionIsPureAndDeterministic() {
        let now = Self.start.advanced(by: .seconds(44))
        let firstEvaluation = EditWatcher.shouldContinuePolling(now: now, deadline: Self.deadline, settingEnabled: true)
        let secondEvaluation = EditWatcher.shouldContinuePolling(now: now, deadline: Self.deadline, settingEnabled: true)
        #expect(firstEvaluation == secondEvaluation)
        #expect(firstEvaluation)
    }
}
