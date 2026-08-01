import Foundation
import Testing
@testable import FreeTalker

@Suite struct UsageStatisticsTests {
    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func row(
        daysAgo: Int = 0,
        hour: Int = 12,
        language: String = "en",
        template: String = "Clean",
        engine: String = "local",
        bundleID: String? = "com.apple.TextEdit",
        durationSecs: Double? = nil,
        refined: String = "hello world",
        transcript: String = "",
        requestedOutputLanguage: OutputLanguage = .sameAsSpoken
    ) -> DictationStatRow {
        let calendar = utcCalendar()
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: hour))!
        let timestamp = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return DictationStatRow(
            timestamp: timestamp, language: language, template: template, engine: engine,
            bundleID: bundleID, durationSecs: durationSecs, refined: refined, transcript: transcript,
            requestedOutputLanguage: requestedOutputLanguage
        )
    }

    private static var referenceNow: Date {
        utcCalendar().date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 12))!
    }

    // MARK: - Word count (Unicode)

    @Test func wordCountSplitsOnUnicodeWhitespace() {
        #expect(UsageStatsSnapshot.wordCount("hello world") == 2)
        #expect(UsageStatsSnapshot.wordCount("hello\tworld\nagain") == 3)
        #expect(UsageStatsSnapshot.wordCount("  leading and trailing  ") == 3)
        #expect(UsageStatsSnapshot.wordCount("multiple   spaces   collapse") == 3)
        #expect(UsageStatsSnapshot.wordCount("") == 0)
        #expect(UsageStatsSnapshot.wordCount("   ") == 0)
        // A CJK run with no whitespace is one unbroken "word" under whitespace-splitting —
        // this is the documented behavior (F4.4: split on Unicode whitespace/newlines only,
        // not locale-aware segmentation), not a bug to "fix" here.
        #expect(UsageStatsSnapshot.wordCount("你好世界") == 1)
        #expect(UsageStatsSnapshot.wordCount("你好 世界") == 2)
        // Non-breaking space and other Unicode separators are whitespace per Character.isWhitespace.
        #expect(UsageStatsSnapshot.wordCount("caf\u{00A0}latte") == 2)
    }

    // MARK: - Aggregate grouping, including NULL bucketing

    @Test func nullBundleIDGroupsUnderUntracked() {
        let rows = [
            Self.row(bundleID: "com.apple.TextEdit"),
            Self.row(bundleID: nil),
            Self.row(bundleID: nil),
        ]
        let snapshot = UsageStatsSnapshot.compute(rows: rows, now: Self.referenceNow, calendar: Self.utcCalendar())
        let untracked = snapshot.byApp.first { $0.key == UsageStatsSnapshot.untrackedAppKey }
        #expect(untracked?.count == 2)
        let tracked = snapshot.byApp.first { $0.key == "com.apple.TextEdit" }
        #expect(tracked?.count == 1)
    }

    @Test func splitsSortDescendingByCountThenAscendingByKey() {
        let rows = [
            Self.row(template: "A"), Self.row(template: "A"),
            Self.row(template: "B"),
            Self.row(template: "C"), Self.row(template: "C"),
        ]
        let snapshot = UsageStatsSnapshot.compute(rows: rows, now: Self.referenceNow, calendar: Self.utcCalendar())
        #expect(snapshot.byTemplate.map(\.key) == ["A", "C", "B"])
    }

    // MARK: - Time-saved formula (SECONDS, clamped at zero)

    @Test func timeSavedClampsAtZeroAndOnlyCountsRowsWithDuration() {
        // 2 words at 40 WPM -> 3 seconds of "typing time". A 10s recording exceeds that, so this
        // row's contribution must clamp to 0, not go negative.
        let overBudget = Self.row(durationSecs: 10, refined: "two words")
        // 100 words at 40 WPM -> 150s typing time, minus a 5s recording -> 145s saved.
        let underBudget = Self.row(durationSecs: 5, refined: Array(repeating: "w", count: 100).joined(separator: " "))
        // No duration recorded at all -> excluded entirely, not treated as 0.
        let noDuration = Self.row(durationSecs: nil, refined: "irrelevant text here")

        let snapshot = UsageStatsSnapshot.compute(
            rows: [overBudget, underBudget, noDuration], now: Self.referenceNow, calendar: Self.utcCalendar()
        )

        #expect(snapshot.rowsWithDuration == 2)
        #expect(abs(snapshot.timeSavedSeconds - 145) < 0.001)
        #expect(snapshot.totalDictations == 3)
    }

    // MARK: - Trailing 30-day window (today inclusive, back 29)

    @Test func dailyCountsCoverTrailingThirtyDaysTodayInclusive() {
        let rows = [
            Self.row(daysAgo: 0),
            Self.row(daysAgo: 29),
            Self.row(daysAgo: 30), // outside the window — must not appear
        ]
        let snapshot = UsageStatsSnapshot.compute(rows: rows, now: Self.referenceNow, calendar: Self.utcCalendar())

        #expect(snapshot.dailyCounts.count == 30)
        #expect(snapshot.dailyCounts.first?.count == 1) // 29 days ago = window start
        #expect(snapshot.dailyCounts.last?.count == 1) // today = window end
        #expect(snapshot.dailyCounts.map(\.count).reduce(0, +) == 2)
        #expect(snapshot.totalDictations == 3)
    }

    @Test func activeDaysCountsDistinctCalendarDaysAcrossFullHistory() {
        let rows = [
            Self.row(daysAgo: 0), Self.row(daysAgo: 0),
            Self.row(daysAgo: 100),
        ]
        let snapshot = UsageStatsSnapshot.compute(rows: rows, now: Self.referenceNow, calendar: Self.utcCalendar())
        #expect(snapshot.activeDays == 2)
        #expect(snapshot.totalDictations == 3)
    }

    @Test func totalWordsSumsAcrossAllRows() {
        let rows = [
            Self.row(refined: "one two three"),
            Self.row(refined: "four five"),
        ]
        let snapshot = UsageStatsSnapshot.compute(rows: rows, now: Self.referenceNow, calendar: Self.utcCalendar())
        #expect(snapshot.totalWords == 5)
    }

    // MARK: - Refined-else-transcript fallback (Codex finding: raw-only/legacy rows counted as
    // zero words) — same rule as `HistoryPanelRow.displayText`.

    @Test func rawOnlyRowFallsBackToTranscriptForWordCountAndTimeSaved() {
        // `refined` empty (never post-processed, e.g. skip-post-processing or a legacy row) must
        // still contribute its transcript's word count and time-saved estimate, not zero.
        let rawOnly = Self.row(durationSecs: 1, refined: "", transcript: "five raw words here now")
        let refinedRow = Self.row(refined: "two words")

        let snapshot = UsageStatsSnapshot.compute(
            rows: [rawOnly, refinedRow], now: Self.referenceNow, calendar: Self.utcCalendar()
        )

        #expect(snapshot.totalWords == 7)
        #expect(snapshot.rowsWithDuration == 1)
        // 5 words at 40 WPM -> 7.5s typing time, minus a 1s recording -> 6.5s saved.
        #expect(abs(snapshot.timeSavedSeconds - 6.5) < 0.001)
    }

    @Test func refinedRowNeverFallsBackToTranscriptEvenWhenTranscriptIsLonger() {
        let row = Self.row(refined: "one", transcript: "one two three four five")
        let snapshot = UsageStatsSnapshot.compute(rows: [row], now: Self.referenceNow, calendar: Self.utcCalendar())
        #expect(snapshot.totalWords == 1)
    }

    // MARK: - Database integration: statRows() round-trips what insertDictation stored

    @Test func statRowsReflectsInsertedBundleIDAndDuration() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("freetalker-usage-stats-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }
        let db = try Database(path: url)
        _ = try db.insertDictation(.init(
            timestamp: Date(), sourceLanguage: SourceLanguage("en"),
            requestedOutputLanguage: .sameAsSpoken, template: "Clean",
            transcript: "raw", refined: "hello world", engine: "local",
            bundleID: "com.apple.TextEdit", durationSecs: 3.5
        ))
        _ = try db.insertDictation(.init(
            timestamp: Date(), sourceLanguage: SourceLanguage("pt"),
            requestedOutputLanguage: .sameAsSpoken, template: "Clean",
            transcript: "raw2", refined: "duas palavras", engine: "local"
        ))

        let rows = try db.statRows()
        #expect(rows.count == 2)
        let tracked = try #require(rows.first { $0.bundleID == "com.apple.TextEdit" })
        #expect(tracked.durationSecs == 3.5)
        #expect(tracked.refined == "hello world")
        #expect(tracked.requestedOutputLanguage == .sameAsSpoken)
        let untracked = try #require(rows.first { $0.bundleID == nil })
        #expect(untracked.durationSecs == nil)

        let snapshot = UsageStatsSnapshot.compute(rows: rows, now: Date(), calendar: .current)
        #expect(snapshot.totalDictations == 2)
        #expect(snapshot.rowsWithDuration == 1)
    }

    // MARK: - Speech insights: pace, averages, longest, vocabulary, rewrite share

    @Test func speakingPaceCountsOnlyRowsWithPositiveDuration() {
        // 60 words over 60s -> 60 wpm. The nil-duration and 0-duration rows contribute words to
        // `totalWords` but must not reach the pace numerator or denominator.
        let sixtyWords = Array(repeating: "w", count: 60).joined(separator: " ")
        let rows = [
            Self.row(durationSecs: 60, refined: sixtyWords),
            Self.row(durationSecs: nil, refined: "excluded from pace"),
            Self.row(durationSecs: 0, refined: "also excluded"),
        ]
        let snapshot = UsageStatsSnapshot.compute(rows: rows, now: Self.referenceNow, calendar: Self.utcCalendar())

        #expect(snapshot.rowsWithPositiveDuration == 1)
        #expect(snapshot.wordsWithDuration == 60)
        #expect(abs(snapshot.speakingSeconds - 60) < 0.001)
        #expect(abs((snapshot.wordsPerMinute ?? 0) - 60) < 0.001)
        // Still counted for time-saved (a 0-duration row has a non-NULL duration).
        #expect(snapshot.rowsWithDuration == 2)
        #expect(snapshot.totalWords == 65)
    }

    @Test func speakingPaceCountsSpokenWordsNotProducedText() {
        // A PT→EN row: 30 English words came out of 60 seconds of Portuguese speech. Pace must
        // measure the 90 words that were actually said, not the translation's word count.
        let spoken = Array(repeating: "palavra", count: 90).joined(separator: " ")
        let translated = Array(repeating: "word", count: 30).joined(separator: " ")
        let row = Self.row(
            language: "pt", durationSecs: 60, refined: translated, transcript: spoken,
            requestedOutputLanguage: .english
        )
        let snapshot = UsageStatsSnapshot.compute(rows: [row], now: Self.referenceNow, calendar: Self.utcCalendar())

        #expect(snapshot.wordsWithDuration == 90)
        #expect(abs((snapshot.wordsPerMinute ?? 0) - 90) < 0.001)
        // The delivered text is still what `totalWords` counts — that metric is about output.
        #expect(snapshot.totalWords == 30)
    }

    @Test func zeroAndMissingDurationsLeavePaceUnavailableRatherThanInfinite() {
        let rows = [Self.row(durationSecs: 0, refined: "some words here"), Self.row(durationSecs: nil)]
        let snapshot = UsageStatsSnapshot.compute(rows: rows, now: Self.referenceNow, calendar: Self.utcCalendar())

        #expect(snapshot.wordsPerMinute == nil)
        #expect(snapshot.averageSecondsPerDictation == nil)
        // The formatter must render the gap, never convert an infinity (which traps in `Int(_:)`).
        #expect(UsageStatisticsFormatting.wordsPerMinute(snapshot.wordsPerMinute) == UsageStatisticsFormatting.unavailable)
        #expect(UsageStatisticsFormatting.duration(.infinity) == UsageStatisticsFormatting.unavailable)
        #expect(UsageStatisticsFormatting.shortDuration(.nan) == UsageStatisticsFormatting.unavailable)
    }

    @Test func emptyHistoryLeavesEveryDerivedMetricUnavailable() {
        let snapshot = UsageStatsSnapshot.compute(rows: [], now: Self.referenceNow, calendar: Self.utcCalendar())

        #expect(snapshot.wordsPerMinute == nil)
        #expect(snapshot.averageWordsPerDictation == nil)
        #expect(snapshot.averageDictationsPerActiveDay == nil)
        #expect(snapshot.refinementRate == nil)
        #expect(snapshot.longestDictation == nil)
        #expect(snapshot.busiestDay == nil)
        #expect(snapshot.peakHour == nil)
        #expect(snapshot.currentStreak == 0)
        #expect(snapshot.longestStreak == 0)
        #expect(snapshot.hourlyCounts.count == 24)
        #expect(snapshot.weekdayCounts.count == 7)
    }

    @Test func averagesDivideOverTheirOwnDenominators() {
        let rows = [
            Self.row(durationSecs: 10, refined: "one two three four"),
            Self.row(durationSecs: nil, refined: "five six"),
        ]
        let snapshot = UsageStatsSnapshot.compute(rows: rows, now: Self.referenceNow, calendar: Self.utcCalendar())

        // Words average over ALL dictations (6 / 2), seconds only over the one that has a duration.
        #expect(abs((snapshot.averageWordsPerDictation ?? 0) - 3) < 0.001)
        #expect(abs((snapshot.averageSecondsPerDictation ?? 0) - 10) < 0.001)
    }

    @Test func longestDictationBreaksTiesTowardTheEarlierRow() {
        let older = Self.row(daysAgo: 3, durationSecs: 12, refined: "one two three")
        let newer = Self.row(daysAgo: 1, refined: "four five six")
        let shorter = Self.row(daysAgo: 0, refined: "seven")

        let ordered = UsageStatsSnapshot.compute(rows: [older, newer, shorter], now: Self.referenceNow, calendar: Self.utcCalendar())
        let reversed = UsageStatsSnapshot.compute(rows: [shorter, newer, older], now: Self.referenceNow, calendar: Self.utcCalendar())

        #expect(ordered.longestDictation?.words == 3)
        #expect(ordered.longestDictation?.date == older.timestamp)
        #expect(ordered.longestDictation?.durationSecs == 12)
        // Row order out of SQLite must not change the answer.
        #expect(reversed.longestDictation == ordered.longestDictation)
    }

    @Test func uniqueWordsIgnoreCasingAndSurroundingPunctuation() {
        let rows = [
            Self.row(refined: "Hello, world!"),
            Self.row(refined: "hello world"),
            Self.row(refined: "world — again"),
        ]
        let snapshot = UsageStatsSnapshot.compute(rows: rows, now: Self.referenceNow, calendar: Self.utcCalendar())

        // hello, world, again — the standalone em dash trims to nothing and is not a word.
        #expect(snapshot.uniqueWords == 3)
        #expect(snapshot.totalWords == 7)
    }

    @Test func rewriteShareExcludesRowsWithNothingToCompare() {
        let rewritten = Self.row(refined: "clean text", transcript: "raw text")
        let untouched = Self.row(refined: "same text", transcript: "same text")
        // `refined` empty means post-processing never ran — not "post-processing changed nothing".
        let rawOnly = Self.row(refined: "", transcript: "raw only row")

        let snapshot = UsageStatsSnapshot.compute(
            rows: [rewritten, untouched, rawOnly], now: Self.referenceNow, calendar: Self.utcCalendar()
        )

        #expect(snapshot.comparableRefinedRows == 2)
        #expect(snapshot.editedByRefinementRows == 1)
        #expect(abs((snapshot.refinementRate ?? 0) - 0.5) < 0.001)
    }

    @Test func rewriteShareExcludesTranslationsAndRawTranscripts() {
        // A translated row's `refined` is another language — always different, never a measure of
        // post-processing.
        let translated = Self.row(refined: "texto limpo", transcript: "clean text", requestedOutputLanguage: .portuguese)
        // Post-processing skipped: `AppCoordinator` records the reserved template name and writes
        // the transcript straight through, so this is "never ran", not "ran and changed nothing".
        let rawTranscript = Self.row(
            template: TemplateStore.rawTranscriptTemplateName,
            refined: "same text", transcript: "same text"
        )
        let rewritten = Self.row(refined: "clean text", transcript: "raw text")

        let snapshot = UsageStatsSnapshot.compute(
            rows: [translated, rawTranscript, rewritten], now: Self.referenceNow, calendar: Self.utcCalendar()
        )

        #expect(snapshot.comparableRefinedRows == 1)
        #expect(snapshot.editedByRefinementRows == 1)
        #expect(abs((snapshot.refinementRate ?? 0) - 1.0) < 0.001)
    }

    @Test func splitsCarryWordsAlongsideCounts() throws {
        let rows = [
            Self.row(bundleID: "com.apple.TextEdit", refined: "one two three"),
            Self.row(bundleID: "com.apple.TextEdit", refined: "four"),
            Self.row(bundleID: nil, refined: "a b c d e"),
        ]
        let snapshot = UsageStatsSnapshot.compute(rows: rows, now: Self.referenceNow, calendar: Self.utcCalendar())

        let tracked = try #require(snapshot.byApp.first { $0.key == "com.apple.TextEdit" })
        #expect(tracked.count == 2)
        #expect(tracked.words == 4)
        let untracked = try #require(snapshot.byApp.first { $0.key == UsageStatsSnapshot.untrackedAppKey })
        #expect(untracked.count == 1)
        #expect(untracked.words == 5)
    }

    // MARK: - Work rhythm: hour/weekday buckets, streaks, busiest day

    @Test func hourlyBucketsCoverTheWholeDayInTheInjectedCalendar() {
        let rows = [Self.row(hour: 9), Self.row(hour: 9), Self.row(hour: 22)]
        let snapshot = UsageStatsSnapshot.compute(rows: rows, now: Self.referenceNow, calendar: Self.utcCalendar())

        #expect(snapshot.hourlyCounts.count == 24)
        #expect(snapshot.hourlyCounts.map(\.hour) == Array(0..<24))
        #expect(snapshot.hourlyCounts.first { $0.hour == 9 }?.count == 2)
        #expect(snapshot.hourlyCounts.first { $0.hour == 22 }?.count == 1)
        #expect(snapshot.peakHour?.hour == 9)
    }

    @Test func peakHourBreaksTiesTowardTheEarlierHour() {
        let rows = [Self.row(hour: 8), Self.row(hour: 17)]
        let snapshot = UsageStatsSnapshot.compute(rows: rows, now: Self.referenceNow, calendar: Self.utcCalendar())
        #expect(snapshot.peakHour?.hour == 8)
    }

    @Test func weekdayBucketsStartAtTheCalendarsFirstWeekday() {
        var mondayFirst = Self.utcCalendar()
        mondayFirst.firstWeekday = 2
        var sundayFirst = Self.utcCalendar()
        sundayFirst.firstWeekday = 1
        let rows = [Self.row(daysAgo: 0), Self.row(daysAgo: 1)]

        let monday = UsageStatsSnapshot.compute(rows: rows, now: Self.referenceNow, calendar: mondayFirst)
        let sunday = UsageStatsSnapshot.compute(rows: rows, now: Self.referenceNow, calendar: sundayFirst)

        #expect(monday.weekdayCounts.map(\.weekday) == [2, 3, 4, 5, 6, 7, 1])
        #expect(sunday.weekdayCounts.map(\.weekday) == [1, 2, 3, 4, 5, 6, 7])
        // Same rows, same totals — only the presentation order rotates.
        #expect(monday.weekdayCounts.map(\.count).reduce(0, +) == 2)
        let referenceWeekday = sundayFirst.component(.weekday, from: Self.referenceNow)
        #expect(sunday.weekdayCounts.first { $0.weekday == referenceWeekday }?.count == 1)
    }

    @Test func currentStreakCountsBackFromTodayAndStopsAtTheGap() {
        let rows = [Self.row(daysAgo: 0), Self.row(daysAgo: 1), Self.row(daysAgo: 2), Self.row(daysAgo: 4)]
        let snapshot = UsageStatsSnapshot.compute(rows: rows, now: Self.referenceNow, calendar: Self.utcCalendar())
        #expect(snapshot.currentStreak == 3)
    }

    @Test func currentStreakSurvivesADayThatHasNoDictationYet() {
        // Nothing dictated today (yet) — the streak anchors on yesterday instead of resetting to 0
        // at local midnight.
        let rows = [Self.row(daysAgo: 1), Self.row(daysAgo: 2)]
        let snapshot = UsageStatsSnapshot.compute(rows: rows, now: Self.referenceNow, calendar: Self.utcCalendar())
        #expect(snapshot.currentStreak == 2)
    }

    @Test func currentStreakIsZeroOnceAFullDayPassedWithNothing() {
        let rows = [Self.row(daysAgo: 2), Self.row(daysAgo: 3)]
        let snapshot = UsageStatsSnapshot.compute(rows: rows, now: Self.referenceNow, calendar: Self.utcCalendar())
        #expect(snapshot.currentStreak == 0)
        #expect(snapshot.longestStreak == 2)
    }

    @Test func longestStreakSpansHistoryNotJustTheTrailingWindow() {
        // A 4-day run 100 days back beats the 2-day run ending today.
        let old = [100, 101, 102, 103].map { Self.row(daysAgo: $0) }
        let recent = [Self.row(daysAgo: 0), Self.row(daysAgo: 1)]
        let snapshot = UsageStatsSnapshot.compute(rows: old + recent, now: Self.referenceNow, calendar: Self.utcCalendar())

        #expect(snapshot.longestStreak == 4)
        #expect(snapshot.currentStreak == 2)
    }

    @Test func busiestDayPicksTheHighestCountAndTiesEarliest() {
        let rows = [
            Self.row(daysAgo: 5), Self.row(daysAgo: 5),
            Self.row(daysAgo: 1), Self.row(daysAgo: 1),
            Self.row(daysAgo: 0),
        ]
        let calendar = Self.utcCalendar()
        let snapshot = UsageStatsSnapshot.compute(rows: rows, now: Self.referenceNow, calendar: calendar)

        let expected = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -5, to: Self.referenceNow)!)
        #expect(snapshot.busiestDay?.count == 2)
        #expect(snapshot.busiestDay?.date == expected)
    }

    @Test func dictationsPerActiveDayDividesByActiveDaysNotCalendarDays() {
        let rows = [Self.row(daysAgo: 0), Self.row(daysAgo: 0), Self.row(daysAgo: 10)]
        let snapshot = UsageStatsSnapshot.compute(rows: rows, now: Self.referenceNow, calendar: Self.utcCalendar())
        #expect(abs((snapshot.averageDictationsPerActiveDay ?? 0) - 1.5) < 0.001)
    }

    // MARK: - Formatting

    @Test func shortDurationKeepsSecondsVisibleBelowTheHour() {
        #expect(UsageStatisticsFormatting.shortDuration(45) == "45s")
        #expect(UsageStatisticsFormatting.shortDuration(90) == "1m 30s")
        #expect(UsageStatisticsFormatting.shortDuration(3660) == "1h 1m")
        // The existing minute-granularity formatter is unchanged.
        #expect(UsageStatisticsFormatting.duration(45) == "0m")
    }

    @Test func percentageAndPaceRenderPlaceholdersForMissingValues() {
        #expect(UsageStatisticsFormatting.percentage(nil) == UsageStatisticsFormatting.unavailable)
        #expect(UsageStatisticsFormatting.decimal(nil) == UsageStatisticsFormatting.unavailable)
        #expect(UsageStatisticsFormatting.wordsPerMinute(132.4) == "132 wpm")
    }
}
