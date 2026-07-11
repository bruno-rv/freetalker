import SwiftUI

enum RecoveryPresentation {
    enum Action: Equatable { case play, retry, delete }
    enum RetryState: Equatable { case available, queued, processing(String), unavailable }

    static let deleteConfirmation = "Permanently delete this recovery and its saved audio? This cannot be undone."

    static func badgeCount(_ jobs: [TranscriptionJob]) -> Int {
        jobs.count { if case .failed = $0.state { true } else { false } }
    }

    static func badgeText(count: Int) -> String? { count == 0 ? nil : String(count) }

    static func expiryText(createdAt: Date, retention: RecoveryRetention, now: Date) -> String {
        guard retention != .never else { return "Kept until deleted" }
        let expiry = createdAt.addingTimeInterval(Double(retention.rawValue) * 86_400)
        let days = Int(ceil(expiry.timeIntervalSince(now) / 86_400))
        return days > 0 ? "Expires in \(days) day\(days == 1 ? "" : "s")" : "Expired — cleanup pending"
    }

    static func actions(for state: JobState) -> [Action] {
        switch state {
        case .failed: [.play, .retry, .delete]
        case .queued: [.play]
        case .processing: [.play]
        case .ready, .cancelled: []
        }
    }

    static func retryState(for state: JobState) -> RetryState {
        switch state {
        case .failed: .available
        case .queued: .queued
        case .processing(let stage): .processing(stageLabel(stage))
        default: .unavailable
        }
    }

    static func retentionLabel(_ value: RecoveryRetention) -> String {
        switch value {
        case .oneDay: "1 day"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .ninetyDays: "90 days"
        case .never: "Never"
        }
    }

    static func stageLabel(_ stage: JobStage) -> String {
        switch stage {
        case .preparing: "Preparing"
        case .transcribing: "Transcribing"
        case .postProcessing: "Post-processing"
        case .persisting: "Saving"
        }
    }

    static func stateLabel(_ state: JobState) -> String {
        switch state {
        case .failed: "Needs attention"
        case .queued: "Queued"
        case .processing(let stage): stageLabel(stage)
        case .ready: "Recovered"
        case .cancelled: "Cancelled"
        }
    }

    static func stateIcon(_ state: JobState) -> String {
        switch state {
        case .failed: "exclamationmark.triangle"
        case .queued: "clock"
        case .processing: "waveform"
        case .ready: "checkmark.circle"
        case .cancelled: "xmark.circle"
        }
    }
}

struct RecoveriesView: View {
    @ObservedObject var store: JobLibraryStore
    @State private var retryJob: TranscriptionJob?
    @State private var pendingDelete: TranscriptionJob?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if store.recoveryJobs.isEmpty {
                ContentUnavailableView("No Recoveries", systemImage: "checkmark.circle", description: Text("Failed dictation audio will appear here so you can listen or try again."))
            } else {
                List(store.recoveryJobs, id: \.id) { job in
                    recoveryRow(job)
                }
            }
        }
        .task { await refresh() }
        .sheet(item: $retryJob) { job in
            RecoveryRetrySheet(job: job, store: store)
        }
        .confirmationDialog("Delete Recovery?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                guard let id = pendingDelete?.id else { return }
                pendingDelete = nil
                Task { do { try await store.delete(id: id) } catch { errorMessage = error.localizedDescription } }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text(RecoveryPresentation.deleteConfirmation) }
        .alert("Recovery Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func recoveryRow(_ job: TranscriptionJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(RecoveryPresentation.stateLabel(job.state), systemImage: RecoveryPresentation.stateIcon(job.state))
                    .font(.headline)
                Spacer()
                Text(job.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
            }
            if case .failed(let failure) = job.state {
                Text("\(RecoveryPresentation.stageLabel(failure.stage)): \(failure.message)")
                    .lineLimit(2).foregroundStyle(.secondary)
            }
            Text(RecoveryPresentation.expiryText(createdAt: job.createdAt, retention: AppSettings.shared.recoveryRetention, now: Date()))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if RecoveryPresentation.actions(for: job.state).contains(.play) {
                    Button("Play", systemImage: "play.fill") { do { try store.play(id: job.id) } catch { errorMessage = error.localizedDescription } }
                        .keyboardShortcut(.space, modifiers: [])
                }
                if RecoveryPresentation.actions(for: job.state).contains(.retry) {
                    Button("Retry…", systemImage: "arrow.clockwise") { retryJob = job }
                }
                Spacer()
                if RecoveryPresentation.actions(for: job.state).contains(.delete) {
                    Button("Delete…", systemImage: "trash", role: .destructive) { pendingDelete = job }
                }
            }
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func refresh() async { do { try await store.refresh() } catch { errorMessage = error.localizedDescription } }
}

extension TranscriptionJob: Identifiable {}
