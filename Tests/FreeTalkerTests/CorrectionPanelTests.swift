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
}
