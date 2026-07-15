import AppKit
import SwiftUI

enum RecoveryPresentation {
    enum Action: Equatable { case play, retry, delete }
    enum RetryState: Equatable { case available, queued, processing(String), unavailable }

    static let deleteConfirmation = "Permanently delete this recovery and its saved audio? This cannot be undone."

    static func badgeCount(_ jobs: [TranscriptionJob], silentCount: Int = 0) -> Int {
        jobs.count { if case .failed = $0.state { true } else { false } } + silentCount
    }

    static func badgeCount(_ items: [RecoveryItem]) -> Int {
        items.count { $0.availableActions.contains(.delete) }
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
        case .queued, .processing: [.play]
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
        case .decoding: "Decoding"
        case .transcribing: "Transcribing"
        case .diarizing: "Separating speakers"
        case .postProcessing: "Post-processing"
        case .persisting: "Saving"
        case .finalizing: "Finalizing"
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

    static func stateLabel(_ item: RecoveryItem) -> String {
        switch item.session?.assetKind {
        case .silent: "No microphone signal"
        case .damaged: "Damaged capture"
        case .quarantined: "Quarantined artifact"
        case .audio, nil: item.job.map { stateLabel($0.state) } ?? "Saved recording"
        }
    }

    static func stateIcon(_ item: RecoveryItem) -> String {
        switch item.session?.assetKind {
        case .silent: "mic.slash"
        case .damaged, .quarantined: "exclamationmark.triangle"
        case .audio, nil: item.job.map { stateIcon($0.state) } ?? "waveform"
        }
    }
}

struct RecoveriesView: View {
    @ObservedObject var store: JobLibraryStore
    @State private var retryJob: TranscriptionJob?
    @State private var pendingDelete: RecoveryItem?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if store.recoveryItems.isEmpty {
                ContentUnavailableView(
                    "No Recoveries", systemImage: "checkmark.circle",
                    description: Text("Interrupted or failed recordings will appear here until you recover or delete them.")
                )
            } else {
                List(store.recoveryItems) { recoveryRow($0) }
            }
        }
        .task { await refresh() }
        .sheet(item: $retryJob) { job in RecoveryRetrySheet(job: job, store: store) }
        .confirmationDialog(
            "Delete Recovery?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let id = pendingDelete?.id else { return }
                pendingDelete = nil
                Task {
                    do { try await store.delete(id: id) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text(RecoveryPresentation.deleteConfirmation) }
        .alert(
            "Recovery Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func recoveryRow(_ item: RecoveryItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    RecoveryPresentation.stateLabel(item),
                    systemImage: RecoveryPresentation.stateIcon(item)
                )
                .font(.headline)
                Spacer()
                Text(item.session?.capturedAt ?? item.job?.createdAt ?? Date(), style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(item.message)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Kept until recovered or explicitly deleted")
                .font(.caption)
                .foregroundStyle(.secondary)
            actionButtons(item)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(RecoveryPresentation.stateLabel(item))
        .accessibilityValue(item.message)
    }

    @ViewBuilder
    private func actionButtons(_ item: RecoveryItem) -> some View {
        HStack {
            if item.availableActions.contains(.retryProcessing), let job = item.job {
                Button("Retry Processing…", systemImage: "arrow.clockwise") { retryJob = job }
                    .help("Process the saved audio again")
                    .accessibilityHint("Opens processing options for this saved recording")
            }
            if item.availableActions.contains(.startNewRecording) {
                Button("Start New Recording", systemImage: "mic") {
                    if !store.startNewRecording(id: item.id) {
                        errorMessage = "A new recording cannot start until Recovery setup and recording storage are available."
                    }
                }
                .help("Start a new external recording")
                .accessibilityHint("Keeps this silent attempt and starts a separate recording")
            }
            if item.availableActions.contains(.exportAudio) {
                Button("Export Audio…", systemImage: "square.and.arrow.up") { export(item) }
                    .help("Copy the saved audio to another location")
                    .accessibilityHint("The recovery copy remains in FreeTalker")
            }
            if item.availableActions.contains(.exportArtifact) {
                Button("Export Artifact…", systemImage: "square.and.arrow.up") { export(item) }
                    .help("Copy the retained diagnostic or damaged artifact")
                    .accessibilityHint("The recovery artifact remains in FreeTalker")
            }
            Spacer()
            if item.availableActions.contains(.delete) {
                Button("Delete…", systemImage: "trash", role: .destructive) {
                    pendingDelete = item
                }
                .help("Permanently delete this recovery")
                .accessibilityHint("Requires confirmation and cannot be undone")
            }
        }
        .labelStyle(.titleAndIcon)
    }

    private func export(_ item: RecoveryItem) {
        let source = item.audioURL ?? item.artifactURL
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = source?.lastPathComponent
            ?? "recovery-\(item.id.uuidString)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try store.export(id: item.id, to: destination) }
        catch { errorMessage = "Could not export the recovery: \(error.localizedDescription)" }
    }

    private func refresh() async {
        do { try await store.refresh() }
        catch { errorMessage = error.localizedDescription }
    }
}

extension TranscriptionJob: Identifiable {}
