import SwiftUI

/// First-run walkthrough content (`BRAINSTORM_INSTALL_AND_UPDATES.md` decision 4): the same
/// three permissions Settings → Privacy already diagnoses, shown with live status, plus the
/// speech model download's progress — so nobody ends up in a half-working state pressing a
/// hotkey that silently does nothing.
struct FirstRunWalkthroughView: View {
    @ObservedObject private var coordinator = AppCoordinator.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var speechModelStore = AppCoordinator.shared.speechModelStore
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to FreeTalker")
                    .font(.title2).bold()
                Text("FreeTalker needs a few permissions to work, and downloads its speech model once. Grant each item below, then continue — you can revisit this anytime in Settings → Privacy.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 0) {
                let items = coordinator.permissionDiagnosis.items
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    permissionRow(item)
                    if index < items.count - 1 {
                        Divider()
                    }
                }
            }

            Divider()

            speechModelSection

            Spacer(minLength: 0)

            HStack {
                Button("Run Diagnosis") { coordinator.refreshPermissionDiagnosis() }
                Spacer()
                Button("Get Started") { onFinish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { coordinator.refreshPermissionDiagnosis() }
    }

    private func permissionRow(_ item: PermissionDiagnosisItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(PermissionDiagnosisPresentation.color(for: item.state))
                    .frame(width: 8, height: 8)
                Text(item.title)
                Spacer()
                if item.showsRelaunch {
                    Button("Relaunch FreeTalker") { AppRelaunch.relaunch() }
                }
                if item.showsOpenSystemSettings {
                    Button("Open System Settings") { PermissionDiagnosisPresentation.openSystemSettings(for: item.kind) }
                }
            }
            Text(item.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var speechModelSection: some View {
        let variant = settings.whisperModel
        let state = speechModelStore.states[variant] ?? SpeechModelStore.State()
        let presentation = SpeechModelRowPresentation.make(
            state: state, selected: false, activeDownloadVariant: speechModelStore.activeDownloadVariant
        )
        // The walkthrough's model IS the active one by definition — `SpeechModelStore.init`
        // marks `settings.whisperModel` active immediately, before it has ever downloaded (see
        // SpeechModelStore.swift:147-149) — so a failed first download leaves `state.active ==
        // true`. `SpeechModelRowPresentation.make`'s `.download` action requires `!state.active`
        // (SettingsView.swift), which is the right call there (you don't manually download an
        // already-active, already-downloaded model) but leaves this specific case — active AND
        // failed — with a status of "Failed — …" and no way to retry. Detect that case here
        // instead of changing the shared Settings presentation, which must stay untouched.
        let isFailed: Bool = {
            if case .failed = state.phase { return true }
            return false
        }()
        let canRetry = isFailed
            && SpeechModelStore.canStartManualDownload(phase: state.phase, reserved: false)
        let waitingOnAnotherDownload = speechModelStore.activeDownloadVariant != nil
        VStack(alignment: .leading, spacing: 6) {
            Text("Speech model").font(.headline)
            HStack {
                Text(SpeechModelCatalog.entry(for: variant)?.displayName ?? variant)
                Spacer()
                Text(presentation.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .downloading(let progress) = state.phase {
                ProgressView(value: progress)
            }
            if presentation.action == .download {
                Button("Download Now") {
                    Task { await speechModelStore.download(variant) }
                }
                .disabled(!presentation.actionEnabled)
            } else if canRetry {
                Button("Retry Download") {
                    Task { await speechModelStore.download(variant) }
                }
                .disabled(waitingOnAnotherDownload)
            }
        }
    }
}
