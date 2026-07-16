import Foundation

/// One Library row projected down to just what the Usage Statistics aggregation needs.
struct DictationStatRow: Sendable, Equatable {
    let timestamp: Date
    let language: String
    let template: String
    let engine: String
    let bundleID: String?
    let durationSecs: Double?
    let refined: String
}

/// A single grouped bucket (by language / template / engine / app).
struct UsageStatSplit: Sendable, Equatable, Identifiable {
    let key: String
    let count: Int
    var id: String { key }
}

/// One local-calendar day's dictation count in the trailing-30-day window.
struct UsageStatDay: Sendable, Equatable, Identifiable {
    let date: Date
    let count: Int
    var id: Date { date }
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

    static let untrackedAppKey = "Untracked"
    /// Typing baseline for the time-saved estimate: 40 words per minute.
    static let typingWordsPerMinute = 40.0
    static let trailingDayCount = 30

    /// Splits a string into words on Unicode whitespace and newlines. `Character.isWhitespace`
    /// already covers spaces, tabs, newlines, and Unicode separators; `split` drops empty runs, so
    /// leading/trailing/repeated separators collapse correctly. See PLAN.md F4.4.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Pure aggregation — no database, no I/O — so every metric is unit-testable in isolation.
    /// `now`/`calendar` are injected so the trailing-window math is deterministic under test.
    static func compute(rows: [DictationStatRow], now: Date, calendar: Calendar) -> UsageStatsSnapshot {
        var snapshot = UsageStatsSnapshot()
        snapshot.totalDictations = rows.count

        var languageCounts: [String: Int] = [:]
        var templateCounts: [String: Int] = [:]
        var engineCounts: [String: Int] = [:]
        var appCounts: [String: Int] = [:]
        var activeDayStarts: Set<Date> = []

        // The window is keyed by the start-of-day for `today - 29 … today`.
        let today = calendar.startOfDay(for: now)
        var windowCounts: [Date: Int] = [:]
        let windowStart = calendar.date(byAdding: .day, value: -(trailingDayCount - 1), to: today) ?? today

        for row in rows {
            let words = wordCount(row.refined)
            snapshot.totalWords += words

            languageCounts[row.language, default: 0] += 1
            templateCounts[row.template, default: 0] += 1
            engineCounts[row.engine, default: 0] += 1
            appCounts[row.bundleID ?? untrackedAppKey, default: 0] += 1

            let dayStart = calendar.startOfDay(for: row.timestamp)
            activeDayStarts.insert(dayStart)
            if dayStart >= windowStart && dayStart <= today {
                windowCounts[dayStart, default: 0] += 1
            }

            if let duration = row.durationSecs {
                snapshot.rowsWithDuration += 1
                let typingSeconds = Double(words) / typingWordsPerMinute * 60.0
                snapshot.timeSavedSeconds += max(0, typingSeconds - duration)
            }
        }

        snapshot.activeDays = activeDayStarts.count
        snapshot.byLanguage = sortedSplits(languageCounts)
        snapshot.byTemplate = sortedSplits(templateCounts)
        snapshot.byEngine = sortedSplits(engineCounts)
        snapshot.byApp = sortedSplits(appCounts)

        snapshot.dailyCounts = (0..<trailingDayCount).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: windowStart) else { return nil }
            return UsageStatDay(date: date, count: windowCounts[date] ?? 0)
        }

        return snapshot
    }

    /// Descending by count, then ascending by key so ties render deterministically.
    private static func sortedSplits(_ counts: [String: Int]) -> [UsageStatSplit] {
        counts.map { UsageStatSplit(key: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
    }
}

/// Owns a dedicated read connection to the Library database and computes the stats snapshot off the
/// main actor. `LibraryStore`'s `Database` handle is `@MainActor` and non-`Sendable`, so it must
/// never be shared across actors — this actor opens its own connection (WAL allows concurrent
/// readers). See PLAN.md F3.3/F4.4.
actor UsageStatsComputer {
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

    private func openIfNeeded() throws -> Database {
        if let database { return database }
        let opened = try Database(path: path)
        database = opened
        return opened
    }
}
