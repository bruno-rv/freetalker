import Foundation
import Testing
@testable import FreeTalker

/// Pure-logic coverage for `CorrectionPanelController.resolveConfirmationPair` (Codex finding 6):
/// once a Swap/Approve-anyway offer is pending, consent must be bound to the EXACT wrong/right
/// pair that produced it — never re-derived from whatever the (still-editable) text field holds
/// at click time. No AX/CGEvent, no live panel/window.
@MainActor
@Suite struct CorrectionPanelTests {
    @Test func withNoPendingOfferUsesTheLiveHeardAndEditedText() {
        let pair = CorrectionPanelController.resolveConfirmationPair(
            dictationID: 1, heardText: "hi joao", editedText: "hi João", pending: nil
        )
        #expect(pair.wrongText == "hi joao")
        #expect(pair.rightText == "hi João")
    }

    /// The core of finding 6: a pending offer's frozen pair wins outright — editing the text
    /// field after the offer appeared (simulated here via a DIFFERENT `editedText`) must not
    /// change what gets confirmed.
    @Test func withAPendingOfferForTheSameDictationTheFrozenPairWinsRegardlessOfLiveEdits() {
        let pending = (dictationID: Int64(1), wrongText: "hi joao", rightText: "hi João", wasPending: true)
        let pair = CorrectionPanelController.resolveConfirmationPair(
            dictationID: 1, heardText: "hi joao", editedText: "SOMETHING THE USER TYPED AFTERWARD",
            pending: pending
        )
        #expect(pair.wrongText == "hi joao")
        #expect(pair.rightText == "hi João")
    }

    /// A pending offer belonging to a DIFFERENT dictation (the panel was reopened for a newer one
    /// without going through a fresh `confirm()`) must never leak into this dictation's pair —
    /// falls back to the live heard/edited text exactly as if nothing were pending.
    @Test func aPendingOfferForADifferentDictationIsIgnored() {
        let pending = (dictationID: Int64(999), wrongText: "old wrong", rightText: "old right", wasPending: true)
        let pair = CorrectionPanelController.resolveConfirmationPair(
            dictationID: 1, heardText: "hi joao", editedText: "hi João", pending: pending
        )
        #expect(pair.wrongText == "hi joao")
        #expect(pair.rightText == "hi João")
    }

    /// `wasPending == false` marks an ORDINARY in-flight first-pass `confirm()` record (set right
    /// before `CorrectionRecorder.record` is even called) — not yet a frozen offer awaiting
    /// re-confirmation, so it must NOT override live text the way a genuine pending offer does.
    @Test func aNonPendingRecordDoesNotOverrideTheLiveText() {
        let inFlight = (dictationID: Int64(1), wrongText: "hi joao", rightText: "hi João", wasPending: false)
        let pair = CorrectionPanelController.resolveConfirmationPair(
            dictationID: 1, heardText: "hi joao", editedText: "hi João Silva", pending: inFlight
        )
        #expect(pair.rightText == "hi João Silva")
    }

    /// Codex Round 2 finding 7: `close()`'s terminal `generation += 1` used to leave the `Task`'s
    /// own `defer { if myGeneration == generation { isBusy = false } }` permanently unable to
    /// fire (the generation it's comparing against was ALREADY bumped by `close()` itself, a few
    /// lines before the defer ever runs) — so a SUCCESSFUL correction's own `close()` call left
    /// `isBusy` stuck `true` for the rest of the process, and `open()`'s `!isBusy` guard refused
    /// every later attempt. `LibraryStore`/`VocabStore` share one real on-disk temp database (see
    /// `LibraryStore.temporaryWithDatabaseURL`) so `CorrectionRecorder.record`'s dictation-id FK
    /// resolves for real, end to end — the same path `AppCoordinator`'s panel wiring exercises.
    @MainActor
    @Test func panelReopensAfterASuccessfulCorrection() async throws {
        let (library, databaseURL) = try LibraryStore.temporaryWithDatabaseURL()
        let id = try library.record(
            language: "en", template: "Clean", transcript: "hi joao how are you",
            refined: "hi joao how are you", engine: "local"
        )
        let vocabStore = try VocabStore(databaseURL: databaseURL)
        var decisionApplied = false
        let controller = CorrectionPanelController(
            store: { vocabStore }, library: library, selectionAccess: NoopSelectionAccess(),
            onDecisionApplied: { decisionApplied = true }
        )

        controller.open()
        #expect(controller.dictation?.id == id)

        controller.corrected = "hi João how are you"
        controller.confirm()
        await controller.waitForCurrentAction()
        #expect(decisionApplied)
        #expect(!controller.isBusy)

        // The regression: every later `open()` used to refuse forever once a correction had ever
        // succeeded once.
        controller.open()
        #expect(controller.dictation?.id == id)
    }
}

/// No-op stand-in for `SelectionAccessing` — `CorrectionPanelController.confirm()`'s live-document
/// repair step only runs when `RecentInsertionStore.shared.recent()` names THIS test's dictation,
/// which it never does here, so `replace`/`capture` are never actually invoked; this only exists
/// to satisfy the initializer without touching real AX.
@MainActor
private final class NoopSelectionAccess: SelectionAccessing {
    func capture() throws -> SelectionSnapshot { throw SelectionAccessError.noFrontmostApplication }
    func replace(_ snapshot: SelectionSnapshot, with text: String) throws { throw SelectionAccessError.noFrontmostApplication }
}
