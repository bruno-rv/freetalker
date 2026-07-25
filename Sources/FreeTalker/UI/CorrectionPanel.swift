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

    /// Codex finding 6: whether a Swap/Approve-anyway confirmation is awaiting the user — the text
    /// field is disabled and `open`/`openForObservedEdit`/`openForPendingOutcome` all refuse to
    /// reopen the panel while this holds, so a fresh trigger can never publish a DIFFERENT
    /// correction's result into an offer that's still awaiting the user's answer.
    var hasPendingConfirmation: Bool { pendingSwap != nil || pendingDismissalOverride != nil }

    private let store: () -> VocabStore?
    private let library: LibraryStore
    private let selectionAccess: any SelectionAccessing
    private let onDecisionApplied: () async -> Void
    private var panel: CorrectionQuickPanel?
    private var actionTask: Task<Void, Never>?
    /// Codex finding 6: the EXACT wrong/right pair a `pendingSwap`/`pendingDismissalOverride`
    /// offer was computed from. The text field stays live-editable while a confirmation is
    /// pending is disabled via `hasPendingConfirmation`, but as extra defense this is what the
    /// interactive Swap/Approve-anyway buttons re-confirm — never whatever `corrected`/`dictation`
    /// happen to hold at click time — so "Drop A for X" can never end up authorising "drop B for
    /// Y". `wasPending` distinguishes "this is a frozen offer being re-confirmed" from "this is
    /// the in-flight record of an ordinary first-pass `confirm()` call" (used only for the
    /// generation-checked async body below, not re-read elsewhere).
    private var confirmedCorrection: (dictationID: Int64, wrongText: String, rightText: String, wasPending: Bool)?
    /// Bumped on every fresh `open`/`openForObservedEdit`/`openForPendingOutcome` (Codex finding
    /// 6) — every UI mutation inside `confirm()`'s `Task`, AFTER each `await`, re-checks this so a
    /// stale task from a panel session that's since been superseded can never publish its result
    /// into the new one.
    private var generation = 0

    /// Pure decision (Codex finding 6), factored out of `confirm()` so "consent is bound to the
    /// exact candidate a Swap/Approve-anyway offer was computed from, not whatever `corrected`
    /// holds at click time" is directly unit-testable without a live panel/AX/store environment —
    /// same style as `Insertion.shouldSynthesizePaste`/`CorrectionRecorder.decide`. When `pending`
    /// names an offer that's ALREADY awaiting confirmation for THIS dictation, its frozen pair
    /// wins outright — `editedText` (the live, still-editable text field) is never consulted, so
    /// editing it between the offer appearing and the user clicking Swap/Approve-anyway cannot
    /// change what gets confirmed. Otherwise (an ordinary first-pass `confirm()`, or a pending
    /// offer that belongs to a DIFFERENT dictation) uses the live `heardText`/`editedText` pair.
    nonisolated static func resolveConfirmationPair(
        dictationID: Int64, heardText: String, editedText: String,
        pending: (dictationID: Int64, wrongText: String, rightText: String, wasPending: Bool)?
    ) -> (wrongText: String, rightText: String) {
        if let pending, pending.dictationID == dictationID, pending.wasPending {
            return (pending.wrongText, pending.rightText)
        }
        return (heardText, editedText)
    }

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
        // Codex finding 6: refuse to reopen (and silently overwrite `dictation`/`corrected`)
        // while an earlier confirmation is still awaiting the user's answer.
        guard !isBusy, !hasPendingConfirmation else { return }
        guard !HistoryPanelController.isBlockedByRecording(
            isRecording: AppCoordinator.shared.isRecording,
            isProcessing: AppCoordinator.shared.isProcessing,
            isCaptureLifecycleActive: AppCoordinator.shared.isCaptureLifecycleActive
        ) else { return }
        generation += 1
        let latest = try? library.latestDictation()
        dictation = latest
        corrected = latest.map { $0.refined.isEmpty ? $0.transcript : $0.refined } ?? ""
        confirmedCorrection = nil
        statusMessage = nil
        pendingSwap = nil
        pendingDismissalOverride = nil
        showPanel()
    }

    func close() {
        guard panel != nil else { return }
        // Codex finding 6: invalidates any in-flight `confirm()` task's remaining generation
        // checks immediately, on top of `actionTask?.cancel()` below.
        generation += 1
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
        guard !isBusy, !hasPendingConfirmation else { return }
        guard !HistoryPanelController.isBlockedByRecording(
            isRecording: AppCoordinator.shared.isRecording,
            isProcessing: AppCoordinator.shared.isProcessing,
            isCaptureLifecycleActive: AppCoordinator.shared.isCaptureLifecycleActive
        ) else { return }
        guard let latest = try? library.latestDictation(), latest.id == dictationID else { return }
        generation += 1
        dictation = latest
        corrected = after
        confirmedCorrection = nil
        statusMessage = "FreeTalker noticed an edit — confirm to remember it"
        pendingSwap = nil
        pendingDismissalOverride = nil
        showPanel()
    }

    /// Correction Loop signals B/C's `.needsDismissalConfirmation`/`.budgetFull` outcomes (Codex
    /// finding 9): those results name a follow-up decision only THIS interactive panel can
    /// complete — Settings can't (dismissed terms are excluded from its suggestions list, and a
    /// single correction sits below the mining recurrence threshold), so directing the user there
    /// was an unreachable dead end. Opens the SAME panel signals A/C already use, pre-loaded with
    /// the immutable wrong/right pair that already produced this outcome — `confirm()` re-confirms
    /// exactly that pair (see `confirmedCorrection`), never re-deriving it from `dictation`/
    /// `corrected`.
    func openForPendingOutcome(dictationID: Int64, wrongText: String, rightText: String, outcome: CorrectionRecorder.Outcome) {
        guard !isBusy, !hasPendingConfirmation else { return }
        guard !HistoryPanelController.isBlockedByRecording(
            isRecording: AppCoordinator.shared.isRecording,
            isProcessing: AppCoordinator.shared.isProcessing,
            isCaptureLifecycleActive: AppCoordinator.shared.isCaptureLifecycleActive
        ) else { return }
        guard let latest = try? library.latestDictation(), latest.id == dictationID else { return }
        generation += 1
        dictation = latest
        corrected = rightText
        confirmedCorrection = (dictationID, wrongText, rightText, true)
        statusMessage = nil
        switch outcome {
        case .needsDismissalConfirmation(let surfaceTerm):
            pendingDismissalOverride = surfaceTerm
            pendingSwap = nil
        case .budgetFull:
            pendingSwap = outcome
            pendingDismissalOverride = nil
        case .approved, .alreadyApproved, .invalidTerm, .noWrongRightPair:
            return
        }
        showPanel()
    }

    /// `confirmSwap`/`confirmDismissedOverride` are re-invocations after the user explicitly
    /// agreed to `pendingSwap`/`pendingDismissalOverride` — never inferred automatically.
    ///
    /// Codex finding 6: when re-confirming an ALREADY-pending offer (`confirmedCorrection.
    /// wasPending`), the wrong/right pair that produced it is reused verbatim — never re-derived
    /// from `dictation.refined`/`corrected`, which may have drifted since (the text field stays
    /// live-editable) — so "Drop A for X" can never end up authorising "drop B for Y." Every UI
    /// mutation inside the `Task` below, after each `await`, re-checks `generation` so a stale
    /// task from a superseded panel session can never publish into this one.
    func confirm(confirmSwap: Bool = false, confirmDismissedOverride: Bool = false) {
        guard let dictation else { return }
        let heard = dictation.refined.isEmpty ? dictation.transcript : dictation.refined
        let (wrongText, rightText) = Self.resolveConfirmationPair(
            dictationID: dictation.id, heardText: heard, editedText: corrected, pending: confirmedCorrection
        )
        guard wrongText != rightText else {
            close()
            return
        }
        let myGeneration = generation
        isBusy = true
        pendingSwap = nil
        pendingDismissalOverride = nil
        confirmedCorrection = (dictation.id, wrongText, rightText, false)
        actionTask = Task {
            defer { if myGeneration == generation { isBusy = false } }
            // Repair the live document FIRST (requirement 3: "any correction repairs the text in
            // place... never silently editing the wrong thing") — reuses the exact same
            // remembered-insertion verification + live-AX-select + SelectionAccess.replace path
            // signal B uses, not a parallel implementation. A drifted/expired/unavailable
            // RecentInsertion just means the live document isn't touched; the vocabulary write
            // below still runs independently — the correction is still real knowledge even when
            // this particular window has closed. Attempted regardless of vocabulary-store
            // availability (Codex finding 15) — the repair and the remembering are independent.
            if let recent = RecentInsertionStore.shared.recent(),
               recent.dictationID == dictation.id, recent.text == wrongText,
               let snapshot = CorrectionTargeting.selectRecentInsertion(recent) {
                try? selectionAccess.replace(snapshot, with: rightText)
            }
            guard myGeneration == generation else { return }

            guard let store = store() else {
                // Codex finding 15: previously returned silently before even attempting the
                // repair above (the whole body was gated on `store()` up front) — no document
                // repair, no error shown. The repair now runs unconditionally; only remembering
                // the term is unavailable.
                statusMessage = "Text updated — remembering this term is unavailable right now"
                return
            }
            guard let outcome = try? await CorrectionRecorder.record(
                dictationID: dictation.id, wrongText: wrongText, rightText: rightText, store: store,
                confirmSwap: confirmSwap, confirmDismissedOverride: confirmDismissedOverride
            ) else {
                guard myGeneration == generation else { return }
                statusMessage = "Could not save the correction"
                return
            }
            guard myGeneration == generation else { return }
            switch outcome {
            case .approved:
                await onDecisionApplied()
                guard myGeneration == generation else { return }
                close()
            case .alreadyApproved:
                close()
            case .noWrongRightPair, .invalidTerm:
                // Text repaired (if possible) above, but nothing single-word enough to learn from
                // — still a successful correction from the user's point of view.
                close()
            case .needsDismissalConfirmation(let surfaceTerm):
                confirmedCorrection = (dictation.id, wrongText, rightText, true)
                pendingDismissalOverride = surfaceTerm
            case .budgetFull:
                confirmedCorrection = (dictation.id, wrongText, rightText, true)
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
                    // Codex finding 6: editing must not change what a Swap/Approve-anyway click
                    // authorises while that offer is pending.
                    .disabled(controller.hasPendingConfirmation || controller.isBusy)

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
