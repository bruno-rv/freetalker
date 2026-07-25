import AppKit
import Combine
import SwiftUI

/// Correction Loop signal A (BRAINSTORM_CORRECTION_LOOP.md): "a panel shows what was heard; the
/// user fixes the word." Same borderless/floating/nonactivating shape as `HistoryQuickPanel` —
/// see that type's doc comment for why `canBecomeKey` is `true` but `canBecomeMain` stays `false`.
private final class CorrectionQuickPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Controller for the correction panel. Opened by its own hotkey (`AppCoordinator.
/// onCorrectionPanelKeyDown`) for the MOST RECENT dictation only (`LibraryStore.
/// latestDictation()` — BRAINSTORM_CORRECTION_LOOP.md requirement 2), gated on the recording
/// state machine exactly like the Dictation History Quick Panel (`HistoryPanelController.
/// isBlockedByRecording`, reused verbatim rather than a second copy).
@MainActor
final class CorrectionPanelController: ObservableObject {
    static let shared = CorrectionPanelController()

    @Published private(set) var dictation: Dictation?
    /// What was heard — the editable field starts here; the user fixes the word in place.
    @Published var corrected: String = ""
    @Published private(set) var statusMessage: String?
    /// Set when `confirm()` hits a budget-full swap offer — the panel shows an explicit
    /// Swap/Cancel choice rather than applying it (requirement 5: never evict silently).
    @Published private(set) var pendingSwap: CorrectionRecorder.Outcome?
    /// Set when `confirm()` finds the term was previously dismissed — shown as an explicit
    /// Approve anyway/Cancel choice (requirement 10: never silently return).
    @Published private(set) var pendingDismissalOverride: String?
    @Published private(set) var isBusy = false

    private let store: () -> VocabStore?
    private let library: LibraryStore
    private let selectionAccess: any SelectionAccessing
    private let onDecisionApplied: () async -> Void
    private var panel: CorrectionQuickPanel?
    private var actionTask: Task<Void, Never>?

    init(
        store: @escaping () -> VocabStore? = { AppCoordinator.shared.vocabStore },
        library: LibraryStore = .shared,
        selectionAccess: any SelectionAccessing = SelectionAccess(),
        onDecisionApplied: @escaping () async -> Void = { await AppCoordinator.shared.refreshApprovedVocabularyCache() }
    ) {
        self.store = store
        self.library = library
        self.selectionAccess = selectionAccess
        self.onDecisionApplied = onDecisionApplied
    }

    /// Lets tests await the in-flight `confirm()` call instead of polling.
    func waitForCurrentAction() async { await actionTask?.value }

    func open() {
        guard !HistoryPanelController.isBlockedByRecording(
            isRecording: AppCoordinator.shared.isRecording,
            isProcessing: AppCoordinator.shared.isProcessing,
            isCaptureLifecycleActive: AppCoordinator.shared.isCaptureLifecycleActive
        ) else { return }
        let latest = try? library.latestDictation()
        dictation = latest
        corrected = latest.map { $0.refined.isEmpty ? $0.transcript : $0.refined } ?? ""
        statusMessage = nil
        pendingSwap = nil
        pendingDismissalOverride = nil
        showPanel()
    }

    func close() {
        guard panel != nil else { return }
        actionTask?.cancel()
        panel?.orderOut(nil)
    }

    /// Correction Loop signal C (`EditWatcher`): opens the SAME panel, pre-filled with the text
    /// the user already typed — `confirm()`'s own live-document repair step naturally no-ops (the
    /// document already reads `after`, so `CorrectionTargeting.selectRecentInsertion` won't match
    /// `dictation.refined` as the still-live ledger text), reducing this to "record the
    /// correction" — the one part signal C actually needs, with the same interactive
    /// swap/dismissal confirmation as every other path through this panel. Silently does nothing
    /// if the dictation no longer matches (deleted, or a newer one has since become "most
    /// recent") or recording is active — same gates `open()` uses.
    func openForObservedEdit(dictationID: Int64, after: String) {
        guard !HistoryPanelController.isBlockedByRecording(
            isRecording: AppCoordinator.shared.isRecording,
            isProcessing: AppCoordinator.shared.isProcessing,
            isCaptureLifecycleActive: AppCoordinator.shared.isCaptureLifecycleActive
        ) else { return }
        guard let latest = try? library.latestDictation(), latest.id == dictationID else { return }
        dictation = latest
        corrected = after
        statusMessage = "FreeTalker noticed an edit — confirm to remember it"
        pendingSwap = nil
        pendingDismissalOverride = nil
        showPanel()
    }

    /// `confirmSwap`/`confirmDismissedOverride` are re-invocations after the user explicitly
    /// agreed to `pendingSwap`/`pendingDismissalOverride` — never inferred automatically.
    func confirm(confirmSwap: Bool = false, confirmDismissedOverride: Bool = false) {
        guard let dictation, let store = store() else { return }
        let heard = dictation.refined.isEmpty ? dictation.transcript : dictation.refined
        let corrected = self.corrected
        guard heard != corrected else {
            close()
            return
        }
        isBusy = true
        pendingSwap = nil
        pendingDismissalOverride = nil
        actionTask = Task {
            defer { isBusy = false }
            // Repair the live document FIRST (requirement 3: "any correction repairs the text in
            // place... never silently editing the wrong thing") — reuses the exact same
            // remembered-insertion verification + live-AX-select + SelectionAccess.replace path
            // signal B uses, not a parallel implementation. A drifted/expired/unavailable
            // RecentInsertion just means the live document isn't touched; the vocabulary write
            // below still runs independently — the correction is still real knowledge even when
            // this particular window has closed.
            if let recent = RecentInsertionStore.shared.recent(),
               recent.dictationID == dictation.id, recent.text == heard,
               let snapshot = CorrectionTargeting.selectRecentInsertion(recent) {
                try? selectionAccess.replace(snapshot, with: corrected)
            }

            guard let outcome = try? await CorrectionRecorder.record(
                dictationID: dictation.id, wrongText: heard, rightText: corrected, store: store,
                confirmSwap: confirmSwap, confirmDismissedOverride: confirmDismissedOverride
            ) else {
                statusMessage = "Could not save the correction"
                return
            }
            switch outcome {
            case .approved:
                await onDecisionApplied()
                close()
            case .alreadyApproved:
                close()
            case .noWrongRightPair, .invalidTerm:
                // Text repaired (if possible) above, but nothing single-word enough to learn from
                // — still a successful correction from the user's point of view.
                close()
            case .needsDismissalConfirmation(let surfaceTerm):
                pendingDismissalOverride = surfaceTerm
            case .budgetFull:
                pendingSwap = outcome
            }
        }
    }

    private func showPanel() {
        let hosting = NSHostingView(rootView: CorrectionPanelContentView(
            controller: self,
            onClose: { [weak self] in self?.close() }
        ))
        let size = NSSize(width: 440, height: 260)
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel: CorrectionQuickPanel
        if let existing = self.panel {
            panel = existing
            panel.contentView = hosting
        } else {
            panel = CorrectionQuickPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.contentView = hosting
            panel.onEscape = { [weak self] in self?.close() }
            self.panel = panel
        }
        if let screen = NSScreen.main {
            let origin = CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)
            panel.setFrameOrigin(origin)
        }
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct CorrectionPanelContentView: View {
    @ObservedObject var controller: CorrectionPanelController
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Correct Last Dictation").font(.headline)
            if let dictation = controller.dictation {
                Text("Heard").font(.caption).foregroundStyle(.secondary)
                Text(dictation.refined.isEmpty ? dictation.transcript : dictation.refined)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text("Fix it").font(.caption).foregroundStyle(.secondary)
                TextField("Corrected text", text: $controller.corrected, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)

                if let surfaceTerm = controller.pendingDismissalOverride {
                    Text("\"\(surfaceTerm)\" was previously dismissed as a suggestion.")
                        .font(.caption)
                    HStack {
                        Button("Approve anyway") { controller.confirm(confirmDismissedOverride: true) }
                        Button("Cancel") { onClose() }
                    }
                } else if case .budgetFull(_, let swapSurface, let newTerm) = controller.pendingSwap {
                    if swapSurface.isEmpty {
                        Text("\"\(newTerm)\" doesn't fit your vocabulary budget.").font(.caption)
                        Button("OK") { onClose() }
                    } else {
                        Text("Vocabulary is full. Drop \"\(swapSurface)\" to learn \"\(newTerm)\"?").font(.caption)
                        HStack {
                            Button("Swap") { controller.confirm(confirmSwap: true) }
                            Button("Cancel") { onClose() }
                        }
                    }
                } else {
                    HStack {
                        Button("Cancel", role: .cancel) { onClose() }
                            .keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Fix It") { controller.confirm() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(controller.isBusy)
                    }
                }
                if let statusMessage = controller.statusMessage {
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("No dictation to correct yet").foregroundStyle(.secondary)
                Button("Close") { onClose() }
            }
        }
        .padding(14)
        .frame(width: 440, height: 260)
        .background(.regularMaterial)
        .onExitCommand(perform: onClose)
    }
}
