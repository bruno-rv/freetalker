import Foundation

/// One Library row projected down to just what the Usage Statistics aggregation needs.
/// `transcript` backs the refined-else-transcript fallback (`UsageStatsSnapshot.wordCount`
/// input) — the same rule `HistoryPanelRow.displayText` uses — so raw-only/legacy rows (no
/// post-processing ever ran, `refined` empty) still contribute their word count and time-saved
/// estimate instead of silently counting as zero. See Codex finding: refined-only word count.
struct DictationStatRow: Sendable, Equatable {
    let timestamp: Date
    let language: String
    let template: String
    let engine: String
    let bundleID: String?
    let durationSecs: Double?
    let refined: String
    let transcript: String
}

/// A single grouped bucket (by language / template / engine / app). `words` is the same
/// refined-else-transcript word count that feeds `UsageStatsSnapshot.totalWords`, so a bucket can
/// be read by volume as well as by frequency — twenty one-line dictations into a chat app and two
/// long ones into a document are the same `count` but very different work.
struct UsageStatSplit: Sendable, Equatable, Identifiable {
    let key: String
    let count: Int
    let words: Int
    var id: String { key }
}

/// One local-calendar day's dictation count in the trailing-30-day window.
struct UsageStatDay: Sendable, Equatable, Identifiable {
    let date: Date
    let count: Int
    var id: Date { date }
}

/// One hour-of-day bucket (0…23), local calendar.
struct UsageStatHour: Sendable, Equatable, Identifiable {
    let hour: Int
    let count: Int
    var id: Int { hour }
}

/// One weekday bucket keyed by the calendar's own `.weekday` component (1…7 — Sunday is 1 in the
/// Gregorian calendar), not a zero-based index, so the view can label it straight from that
/// calendar's localized `shortWeekdaySymbols`.
struct UsageStatWeekday: Sendable, Equatable, Identifiable {
    let weekday: Int
    let count: Int
    var id: Int { weekday }
}

/// The single longest dictation by word count. Ties resolve to the earliest one so the value is
/// stable across recomputes regardless of the order rows come back from SQLite.
struct UsageStatLongest: Sendable, Equatable {
    let words: Int
    let date: Date
    let durationSecs: Double?
}

/// An immutable, `Sendable` snapshot of all Usage Statistics, computed off the main actor and
/// published whole to the page. There is no caching — the page recomputes on every open, so
/// deleting Dictation History deletes the statistics by construction. See PLAN.md F4.3/F4.4.
struct UsageStatsSnapshot: Sendable, Equatable {
    var totalDictations: Int = 0
    var totalWords: Int = 0
    var activeDays: Int = 0
    /// Trailing 30 local-calendar days, oldest first: today back 29.
    var dailyCounts: [UsageStatDay] = []
    var byLanguage: [UsageStatSplit] = []
    var byTemplate: [UsageStatSplit] = []
    var byEngine: [UsageStatSplit] = []
    /// Per-destination-app; a NULL `bundle_id` is bucketed under `untrackedAppKey`.
    var byApp: [UsageStatSplit] = []
    /// Estimated seconds saved versus typing, summed over rows that carry a duration.
    var timeSavedSeconds: Double = 0
    var rowsWithDuration: Int = 0

    // MARK: - Speech insights

    /// Total recorded speaking time, over rows with a strictly positive duration only. A row with a
    /// zero (or negative) `duration_secs` is a degenerate capture, not a zero-length utterance, and
    /// including it would put a 0 in a denominator — see `wordsPerMinute`.
    var speakingSeconds: Double = 0
    /// Rows counted in `speakingSeconds` — the denominator to render next to every pace metric.
    /// Deliberately distinct from `rowsWithDuration` (non-NULL duration, the time-saved
    /// denominator): a zero-duration row still contributes a time-saved estimate but cannot
    /// contribute a rate.
    var rowsWithPositiveDuration: Int = 0
    /// Words from those same rows, so pace is words-over-their-own-time rather than all words over
    /// some rows' time.
    var wordsWithDuration: Int = 0
    var longestDictation: UsageStatLongest?
    /// Distinct lowercased, punctuation-trimmed words across all dictations.
    ///
    /// Deliberately a raw count, not a type/token ratio: TTR shrinks as history grows, so it would
    /// read as the user's vocabulary narrowing when only their corpus grew.
    var uniqueWords: Int = 0
    /// Rows where a comparison between raw and post-processed text is actually meaningful — both
    /// sides non-empty. Legacy/raw-only rows (`refined` empty means post-processing never ran, per
    /// `DictationStatRow`) are excluded rather than counted as "unchanged", which would report a
    /// falsely low edit rate on a history full of them.
    var comparableRefinedRows: Int = 0
    /// Of those, the ones post-processing actually changed.
    var editedByRefinementRows: Int = 0

    // MARK: - Work rhythm

    /// 24 buckets, hour 0…23 in the injected calendar, always all present (zeros included).
    var hourlyCounts: [UsageStatHour] = []
    /// 7 buckets, in the injected calendar's weekday order starting at `firstWeekday`.
    var weekdayCounts: [UsageStatWeekday] = []
    /// Consecutive active days ending today, or ending yesterday when today has no dictation yet —
    /// otherwise the streak would read 0 every morning until the first dictation of the day.
    var currentStreak: Int = 0
    var longestStreak: Int = 0
    /// The single busiest local-calendar day over all history (not just the trailing window). Ties
    /// resolve to the earliest day.
    var busiestDay: UsageStatDay?

    /// Words per minute of actual speech. `nil` (rendered as "—") when nothing has a usable
    /// duration, never a division by zero — `Int(Double.infinity)` traps in Swift and the duration
    /// formatter does exactly that conversion.
    var wordsPerMinute: Double? {
        guard speakingSeconds > 0 else { return nil }
        return Double(wordsWithDuration) / speakingSeconds * 60.0
    }

    var averageWordsPerDictation: Double? {
        guard totalDictations > 0 else { return nil }
        return Double(totalWords) / Double(totalDictations)
    }

    var averageSecondsPerDictation: Double? {
        guard rowsWithPositiveDuration > 0 else { return nil }
        return speakingSeconds / Double(rowsWithPositiveDuration)
    }

    var averageDictationsPerActiveDay: Double? {
        guard activeDays > 0 else { return nil }
        return Double(totalDictations) / Double(activeDays)
    }

    /// Share of comparable rows post-processing rewrote, 0…1.
    var refinementRate: Double? {
        guard comparableRefinedRows > 0 else { return nil }
        return Double(editedByRefinementRows) / Double(comparableRefinedRows)
    }

    /// The busiest hour of the day, or `nil` when there is no dictation at all. Ties resolve to the
    /// earlier hour.
    var peakHour: UsageStatHour? {
        hourlyCounts.filter { $0.count > 0 }.max { left, right in
            left.count != right.count ? left.count < right.count : left.hour > right.hour
        }
    }

    static let untrackedAppKey = "Untracked"
    /// Typing baseline for the time-saved estimate: 40 words per minute.
    static let typingWordsPerMinute = 40.0
    static let trailingDayCount = 30

    /// Splits a string into words on Unicode whitespace and newlines. `Character.isWhitespace`
    /// already covers spaces, tabs, newlines, and Unicode separators; `split` drops empty runs, so
    /// leading/trailing/repeated separators collapse correctly. See PLAN.md F4.4.
    static func wordCount(_ text: String) -> Int {
        words(in: text).count
    }

    /// The word pieces `wordCount` counts, exposed so `compute` can count and normalize a
    /// dictation's text in one pass instead of walking it twice.
    static func words(in text: String) -> [Substring] {
        text.split(whereSeparator: { $0.isWhitespace })
    }

    /// Pure aggregation — no database, no I/O — so every metric is unit-testable in isolation.
    /// `now`/`calendar` are injected so the trailing-window math is deterministic under test.
    static func compute(rows: [DictationStatRow], now: Date, calendar: Calendar) -> UsageStatsSnapshot {
        var snapshot = UsageStatsSnapshot()
        snapshot.totalDictations = rows.count

        var languageTallies: [String: SplitTally] = [:]
        var templateTallies: [String: SplitTally] = [:]
        var engineTallies: [String: SplitTally] = [:]
        var appTallies: [String: SplitTally] = [:]
        var activeDayCounts: [Date: Int] = [:]
        // Unbounded across full history — a personal-scale corpus keeps this in the low hundreds of
        // thousands of entries. If a history ever grows past that, sample rows here rather than
        // making the set lossy, the same way `VocabularyMiner.maxTokenCountForDiff` bounds its own
        // per-row work.
        var distinctWords: Set<String> = []
        var hourCounts: [Int: Int] = [:]
        var weekdayCounts: [Int: Int] = [:]

        // The window is keyed by the start-of-day for `today - 29 … today`.
        let today = calendar.startOfDay(for: now)
        var windowCounts: [Date: Int] = [:]
        let windowStart = calendar.date(byAdding: .day, value: -(trailingDayCount - 1), to: today) ?? today

        for row in rows {
            // Refined-else-transcript (PLAN.md F4.4) — same rule as `HistoryPanelRow.
            // displayText`: a raw-only/legacy row (never post-processed, `refined` empty) still
            // contributes its transcript's word count rather than counting as zero words and
            // zero time-saved.
            let pieces = words(in: row.refined.isEmpty ? row.transcript : row.refined)
            let rowWords = pieces.count
            snapshot.totalWords += rowWords
            for piece in pieces {
                // Punctuation-trimmed and lowercased so "João." and "joão" are one word — the same
                // normalization `VocabularyMiner.tokenize` applies before comparing terms.
                let normalized = piece.trimmingCharacters(in: .punctuationCharacters).lowercased()
                if !normalized.isEmpty { distinctWords.insert(normalized) }
            }

            languageTallies[row.language, default: .zero].add(words: rowWords)
            templateTallies[row.template, default: .zero].add(words: rowWords)
            engineTallies[row.engine, default: .zero].add(words: rowWords)
            appTallies[row.bundleID ?? untrackedAppKey, default: .zero].add(words: rowWords)

            if !row.refined.isEmpty && !row.transcript.isEmpty {
                snapshot.comparableRefinedRows += 1
                if row.refined != row.transcript { snapshot.editedByRefinementRows += 1 }
            }

            if snapshot.longestDictation.map({ rowWords > $0.words || (rowWords == $0.words && row.timestamp < $0.date) }) ?? true {
                snapshot.longestDictation = UsageStatLongest(words: rowWords, date: row.timestamp, durationSecs: row.durationSecs)
            }

            let dayStart = calendar.startOfDay(for: row.timestamp)
            activeDayCounts[dayStart, default: 0] += 1
            hourCounts[calendar.component(.hour, from: row.timestamp), default: 0] += 1
            weekdayCounts[calendar.component(.weekday, from: row.timestamp), default: 0] += 1
            if dayStart >= windowStart && dayStart <= today {
                windowCounts[dayStart, default: 0] += 1
            }

            if let duration = row.durationSecs {
                snapshot.rowsWithDuration += 1
                let typingSeconds = Double(rowWords) / typingWordsPerMinute * 60.0
                snapshot.timeSavedSeconds += max(0, typingSeconds - duration)
                if duration > 0 {
                    snapshot.rowsWithPositiveDuration += 1
                    snapshot.speakingSeconds += duration
                    snapshot.wordsWithDuration += rowWords
                }
            }
        }

        snapshot.activeDays = activeDayCounts.count
        snapshot.uniqueWords = distinctWords.count
        snapshot.byLanguage = sortedSplits(languageTallies)
        snapshot.byTemplate = sortedSplits(templateTallies)
        snapshot.byEngine = sortedSplits(engineTallies)
        snapshot.byApp = sortedSplits(appTallies)

        snapshot.dailyCounts = (0..<trailingDayCount).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: windowStart) else { return nil }
            return UsageStatDay(date: date, count: windowCounts[date] ?? 0)
        }

        snapshot.hourlyCounts = (0..<24).map { UsageStatHour(hour: $0, count: hourCounts[$0] ?? 0) }
        snapshot.weekdayCounts = (0..<7).map { offset in
            // Start at the calendar's own `firstWeekday` so the chart reads Sun→Sat or Mon→Sun to
            // match the user's locale, rather than being hardcoded to either.
            let weekday = (calendar.firstWeekday - 1 + offset) % 7 + 1
            return UsageStatWeekday(weekday: weekday, count: weekdayCounts[weekday] ?? 0)
        }

        snapshot.busiestDay = activeDayCounts
            .map { UsageStatDay(date: $0.key, count: $0.value) }
            .max { left, right in
                left.count != right.count ? left.count < right.count : left.date > right.date
            }

        let activeDayStarts = Set(activeDayCounts.keys)
        snapshot.currentStreak = currentStreak(activeDays: activeDayStarts, today: today, calendar: calendar)
        snapshot.longestStreak = longestStreak(activeDays: activeDayStarts, calendar: calendar)

        return snapshot
    }

    /// Consecutive active days counted backwards from today. A day with no dictation *yet* is not a
    /// broken streak, so when today is empty the count anchors on yesterday instead — otherwise the
    /// streak would drop to 0 at every local midnight and climb back an hour later.
    static func currentStreak(activeDays: Set<Date>, today: Date, calendar: Calendar) -> Int {
        var cursor = today
        if !activeDays.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  activeDays.contains(yesterday) else { return 0 }
            cursor = yesterday
        }
        var streak = 0
        while activeDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    /// Longest run of consecutive active days anywhere in history.
    static func longestStreak(activeDays: Set<Date>, calendar: Calendar) -> Int {
        var longest = 0
        for day in activeDays {
            // Only start counting from the first day of a run, so each run is walked once.
            let previous = calendar.date(byAdding: .day, value: -1, to: day)
            if let previous, activeDays.contains(previous) { continue }
            var run = 0
            var cursor = day
            while activeDays.contains(cursor) {
                run += 1
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            longest = max(longest, run)
        }
        return longest
    }

    /// Per-bucket accumulator — dictations and their words together, so both are gathered in the
    /// one pass over the rows.
    private struct SplitTally {
        var count = 0
        var words = 0
        static let zero = SplitTally()
        mutating func add(words newWords: Int) {
            count += 1
            words += newWords
        }
    }

    /// Descending by count, then ascending by key so ties render deterministically.
    private static func sortedSplits(_ tallies: [String: SplitTally]) -> [UsageStatSplit] {
        tallies.map { UsageStatSplit(key: $0.key, count: $0.value.count, words: $0.value.words) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
    }
}

/// Owns ONE dedicated read connection to the Library database, off the main actor.
/// `LibraryStore`'s `Database` handle is `@MainActor` and non-`Sendable`, so it must never be
/// shared across actors — this actor opens its own connection (WAL allows concurrent readers).
/// Serves both Usage Statistics (`compute`, F4.4) and the Dictation History Quick Panel's search
/// (`search`, F3.3) — one actor-owned connection, not two parallel ones, per PLAN.md F3.3's "the
/// same actor-owned read connection serves F4's stats computation."
actor LibraryReadActor {
    private let path: URL
    private var database: Database?

    init(path: URL = Database.defaultURL) {
        self.path = path
    }

    func compute(now: Date = Date(), calendar: Calendar = .current) throws -> UsageStatsSnapshot {
        let database = try openIfNeeded()
        let rows = try database.statRows()
        return UsageStatsSnapshot.compute(rows: rows, now: now, calendar: calendar)
    }

    /// Bounded, debounced search for the Dictation History Quick Panel (PLAN.md F3.3). Delegates
    /// to `Database.search(query:limit:)` — the ONE search path also used by `LibraryStore`'s
    /// (unlimited) Library view search — from this actor's own connection, never `LibraryStore`'s
    /// main-actor one.
    func search(query: String, limit: Int) throws -> [Dictation] {
        let database = try openIfNeeded()
        return try database.search(query: query, limit: limit)
    }

    private func openIfNeeded() throws -> Database {
        if let database { return database }
        let opened = try Database(path: path)
        database = opened
        return opened
    }
}
