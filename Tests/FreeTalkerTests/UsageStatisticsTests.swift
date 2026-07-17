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
        language: String = "en",
        template: String = "Clean",
        engine: String = "local",
        bundleID: String? = "com.apple.TextEdit",
        durationSecs: Double? = nil,
        refined: String = "hello world",
        transcript: String = ""
    ) -> DictationStatRow {
        let calendar = utcCalendar()
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 12))!
        let timestamp = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return DictationStatRow(
            timestamp: timestamp, language: language, template: template, engine: engine,
            bundleID: bundleID, durationSecs: durationSecs, refined: refined, transcript: transcript
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
        let untracked = try #require(rows.first { $0.bundleID == nil })
        #expect(untracked.durationSecs == nil)

        let snapshot = UsageStatsSnapshot.compute(rows: rows, now: Date(), calendar: .current)
        #expect(snapshot.totalDictations == 2)
        #expect(snapshot.rowsWithDuration == 1)
    }
}
