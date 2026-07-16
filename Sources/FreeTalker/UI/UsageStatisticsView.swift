import SwiftUI

/// Formats a metrics summary card. Kept separate from the view body so the numeric formatting is
/// unit-testable without instantiating SwiftUI.
enum UsageStatisticsFormatting {
    static func duration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    static func dayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
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
                        Text(UsageStatisticsFormatting.count(split.count))
                            .foregroundStyle(.secondary)
                    }
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

struct UsageStatisticsView: View {
    /// Whether this is the currently-selected Settings tab. Recompute is triggered whenever this
    /// flips to `true` — the page has no cache, matching PLAN.md F4.4 ("recompute on page open").
    let isActive: Bool

    /// Held for the view's lifetime so opening the page repeatedly reuses the same read
    /// connection rather than reopening the Library database (which re-runs migrations) each time.
    @State private var computer = UsageStatsComputer()
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

            SettingsCard(title: "Activity") {
                UsageDailyActivityChart(days: snapshot.dailyCounts)
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
