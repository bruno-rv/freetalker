import SwiftUI

/// Formats a metrics summary card. Kept separate from the view body so the numeric formatting is
/// unit-testable without instantiating SwiftUI.
enum UsageStatisticsFormatting {
    /// Rendered in place of any metric whose denominator is zero — no dictations yet, or none with
    /// a usable duration. Never a 0 or a NaN.
    static let unavailable = "—"

    static func duration(_ seconds: Double) -> String {
        // `Int(_:)` traps on infinity/NaN, and every duration here is a sum or a quotient, so the
        // guard is on the conversion rather than on each call site.
        guard seconds.isFinite else { return unavailable }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Like `duration`, but keeps seconds visible below the hour mark — a 45-second average
    /// dictation renders "45s", not "0m".
    static func shortDuration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return unavailable }
        let totalSeconds = Int(seconds.rounded())
        if totalSeconds >= 3600 { return duration(seconds) }
        if totalSeconds >= 60 { return "\(totalSeconds / 60)m \(totalSeconds % 60)s" }
        return "\(totalSeconds)s"
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    static func decimal(_ value: Double?) -> String {
        guard let value, value.isFinite else { return unavailable }
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    static func wordsPerMinute(_ value: Double?) -> String {
        guard let value, value.isFinite else { return unavailable }
        return "\(Int(value.rounded())) wpm"
    }

    /// A 0…1 share as a whole-percent string.
    static func percentage(_ value: Double?) -> String {
        guard let value, value.isFinite else { return unavailable }
        return value.formatted(.percent.precision(.fractionLength(0)))
    }

    static func dayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func hourLabel(_ hour: Int) -> String {
        String(format: "%02d", hour)
    }

    /// Localized short weekday name for a `Calendar.component(.weekday)` value (1-based).
    static func weekdayLabel(_ weekday: Int, calendar: Calendar = .current) -> String {
        let symbols = calendar.shortWeekdaySymbols
        let index = weekday - 1
        guard symbols.indices.contains(index) else { return "\(weekday)" }
        return symbols[index]
    }
}

private struct UsageStatSplitList: View {
    let title: String
    let splits: [UsageStatSplit]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if splits.isEmpty {
                Text("No data yet").foregroundStyle(.secondary)
            } else {
                ForEach(splits) { split in
                    HStack {
                        Text(split.key)
                        Spacer()
                        Text("\(UsageStatisticsFormatting.count(split.count)) · \(UsageStatisticsFormatting.count(split.words)) words")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(split.key): \(split.count) dictations, \(split.words) words")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UsageDailyActivityChart: View {
    let days: [UsageStatDay]

    private var maxCount: Int { max(days.map(\.count).max() ?? 0, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dictations per day (last 30 days)").font(.headline)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(days) { day in
                    VStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor.opacity(day.count > 0 ? 0.85 : 0.15))
                            .frame(height: max(2, CGFloat(day.count) / CGFloat(maxCount) * 60))
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("\(UsageStatisticsFormatting.dayLabel(day.date)): \(day.count) dictations")
                }
            }
            .frame(height: 60, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One labelled column of the hour-of-day / weekday histograms.
private struct UsageHistogramBar: Identifiable {
    let id: Int
    let label: String
    let count: Int
    /// Spoken description for VoiceOver — "09:00" alone is not enough to know what is being counted.
    let accessibilityLabel: String
}

/// Shared bar chart for the two rhythm histograms. `labelStride` thins the captions: 24 hourly
/// captions do not fit across a Settings pane, 7 weekday ones do.
private struct UsageHistogramChart: View {
    let title: String
    let bars: [UsageHistogramBar]
    var labelStride: Int = 1

    private var maxCount: Int { max(bars.map(\.count).max() ?? 0, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(bars.enumerated()), id: \.element.id) { index, bar in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor.opacity(bar.count > 0 ? 0.85 : 0.15))
                            .frame(height: max(2, CGFloat(bar.count) / CGFloat(maxCount) * 50))
                        // A caption's intrinsic width would otherwise widen its column and push the
                        // 24-bar chart past the Settings pane, so it shrinks to the column instead.
                        Text(index % labelStride == 0 ? bar.label : " ")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    .frame(maxWidth: .infinity, alignment: .bottom)
                    .accessibilityLabel(bar.accessibilityLabel)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UsageStatisticsView: View {
    /// Whether this is the currently-selected Settings tab. Recompute is triggered whenever this
    /// flips to `true` — the page has no cache, matching PLAN.md F4.4 ("recompute on page open").
    let isActive: Bool

    /// Held for the view's lifetime so opening the page repeatedly reuses the same read
    /// connection rather than reopening the Library database (which re-runs migrations) each time.
    @State private var computer = LibraryReadActor()
    @State private var snapshot: UsageStatsSnapshot?
    @State private var isComputing = false
    @State private var loadError: String?

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

    var body: some View {
        SettingsPage(
            title: "Usage Statistics",
            subtitle: "Derived from Dictation History. Deleting a dictation removes it from these statistics — there is no separate copy."
        ) {
            if isComputing && snapshot == nil {
                ProgressView("Computing statistics…")
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if let loadError {
                Text(loadError).foregroundStyle(.secondary)
            } else if let snapshot {
                content(for: snapshot)
            } else {
                Text("No data yet").foregroundStyle(.secondary)
            }
        }
        .task(id: isActive) {
            guard isActive else { return }
            await recompute()
        }
    }

    @ViewBuilder
    private func content(for snapshot: UsageStatsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "Overview") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Total dictations", value: UsageStatisticsFormatting.count(snapshot.totalDictations))
                    LabeledContent("Total words", value: UsageStatisticsFormatting.count(snapshot.totalWords))
                    LabeledContent("Active days", value: UsageStatisticsFormatting.count(snapshot.activeDays))
                    LabeledContent("Estimated time saved", value: UsageStatisticsFormatting.duration(snapshot.timeSavedSeconds))
                    Text("Time saved is estimated at 40 words per minute of typing, minus actual recording time, computed only over the \(snapshot.rowsWithDuration) of \(snapshot.totalDictations) dictations that have recorded duration.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard(title: "Speech", subtitle: "How you actually speak, measured over your dictation history.") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Speaking pace", value: UsageStatisticsFormatting.wordsPerMinute(snapshot.wordsPerMinute))
                    LabeledContent("Average dictation", value: averageDictationSummary(snapshot))
                    LabeledContent("Longest dictation", value: longestDictationSummary(snapshot))
                    LabeledContent("Total speaking time", value: UsageStatisticsFormatting.shortDuration(snapshot.speakingSeconds))
                    LabeledContent("Distinct words used", value: UsageStatisticsFormatting.count(snapshot.uniqueWords))
                    LabeledContent("Rewritten by post-processing", value: UsageStatisticsFormatting.percentage(snapshot.refinementRate))
                    Text("Pace and speaking time cover the \(snapshot.rowsWithPositiveDuration) of \(snapshot.totalDictations) dictations with a recorded duration. The rewrite share covers the \(snapshot.comparableRefinedRows) that were post-processed by a template — raw-only dictations have nothing to compare against.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard(title: "Activity") {
                UsageDailyActivityChart(days: snapshot.dailyCounts)
            }

            SettingsCard(title: "Work rhythm", subtitle: "When the dictating happens.") {
                VStack(alignment: .leading, spacing: 16) {
                    UsageHistogramChart(title: "By hour of day", bars: hourBars(snapshot), labelStride: 3)
                    UsageHistogramChart(title: "By weekday", bars: weekdayBars(snapshot))
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Peak hour", value: peakHourSummary(snapshot))
                        LabeledContent("Busiest day", value: busiestDaySummary(snapshot))
                        LabeledContent("Dictations per active day", value: UsageStatisticsFormatting.decimal(snapshot.averageDictationsPerActiveDay))
                        LabeledContent("Current streak", value: dayCountSummary(snapshot.currentStreak))
                        LabeledContent("Longest streak", value: dayCountSummary(snapshot.longestStreak))
                    }
                    Text("A streak counts consecutive days with at least one dictation; it holds until a full day passes with none, so it does not reset at midnight.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard(title: "Breakdown") {
                VStack(alignment: .leading, spacing: 16) {
                    UsageStatSplitList(title: "By language", splits: snapshot.byLanguage)
                    UsageStatSplitList(title: "By template", splits: snapshot.byTemplate)
                    UsageStatSplitList(title: "By engine", splits: snapshot.byEngine)
                    UsageStatSplitList(title: "By app", splits: snapshot.byApp)
                }
            }
        }
    }

    private func averageDictationSummary(_ snapshot: UsageStatsSnapshot) -> String {
        guard let words = snapshot.averageWordsPerDictation else { return UsageStatisticsFormatting.unavailable }
        let wordsText = "\(UsageStatisticsFormatting.decimal(words)) words"
        guard let seconds = snapshot.averageSecondsPerDictation else { return wordsText }
        return "\(wordsText) · \(UsageStatisticsFormatting.shortDuration(seconds))"
    }

    private func longestDictationSummary(_ snapshot: UsageStatsSnapshot) -> String {
        guard let longest = snapshot.longestDictation else { return UsageStatisticsFormatting.unavailable }
        let words = "\(UsageStatisticsFormatting.count(longest.words)) words"
        let day = UsageStatisticsFormatting.dayLabel(longest.date)
        guard let duration = longest.durationSecs, duration > 0 else { return "\(words) · \(day)" }
        return "\(words) · \(UsageStatisticsFormatting.shortDuration(duration)) · \(day)"
    }

    private func peakHourSummary(_ snapshot: UsageStatsSnapshot) -> String {
        guard let peak = snapshot.peakHour else { return UsageStatisticsFormatting.unavailable }
        return "\(UsageStatisticsFormatting.hourLabel(peak.hour)):00 · \(UsageStatisticsFormatting.count(peak.count)) dictations"
    }

    private func busiestDaySummary(_ snapshot: UsageStatsSnapshot) -> String {
        guard let busiest = snapshot.busiestDay else { return UsageStatisticsFormatting.unavailable }
        return "\(UsageStatisticsFormatting.dayLabel(busiest.date)) · \(UsageStatisticsFormatting.count(busiest.count)) dictations"
    }

    private func dayCountSummary(_ days: Int) -> String {
        days == 1 ? "1 day" : "\(UsageStatisticsFormatting.count(days)) days"
    }

    private func hourBars(_ snapshot: UsageStatsSnapshot) -> [UsageHistogramBar] {
        snapshot.hourlyCounts.map { hour in
            UsageHistogramBar(
                id: hour.hour,
                label: UsageStatisticsFormatting.hourLabel(hour.hour),
                count: hour.count,
                accessibilityLabel: "\(UsageStatisticsFormatting.hourLabel(hour.hour)):00: \(hour.count) dictations"
            )
        }
    }

    private func weekdayBars(_ snapshot: UsageStatsSnapshot) -> [UsageHistogramBar] {
        snapshot.weekdayCounts.map { weekday in
            let label = UsageStatisticsFormatting.weekdayLabel(weekday.weekday)
            return UsageHistogramBar(
                id: weekday.weekday,
                label: label,
                count: weekday.count,
                accessibilityLabel: "\(label): \(weekday.count) dictations"
            )
        }
    }

    private func recompute() async {
        isComputing = true
        loadError = nil
        defer { isComputing = false }
        do {
            snapshot = try await computer.compute()
        } catch {
            loadError = "Could not compute statistics: \(error.localizedDescription)"
        }
    }
}
