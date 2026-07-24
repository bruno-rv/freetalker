import Testing
@testable import FreeTalker

/// Pure-logic coverage for the Codex-review hardening around live-streaming insertion
/// (BRAINSTORM_STREAMING_ASR.md): the collapsed-selection start gate (finding 1), refusing to
/// backspace on an unverified readback (findings 2, 3, 5), and capture-generation ownership
/// (finding 7). None of these post real `CGEvent`s or touch live AX/AppKit state — every function
/// under test is a `nonisolated static` value computation, mirroring the existing
/// `Insertion.classifyPreflightFailure`/`shouldSynthesizePaste` split of decision from effect.
@Suite struct StreamingASRSafetyTests {
    // MARK: - Finding 1: collapsed-selection start gate

    @Test func shouldStreamLiveRequiresCollapsedSelection() {
        #expect(AppCoordinator.shouldStreamLive(
            streamingEnabled: true, streamingModelDownloaded: true, sttEngine: .whisperKit,
            forcedLanguage: "en", isSecureField: false, hasCollapsedSelection: true,
            hasInsertionTarget: true
        ))
        // A real (non-collapsed) selection — or an unreadable one, which the caller already
        // normalizes to `false` — must never allow streaming to start.
        #expect(!AppCoordinator.shouldStreamLive(
            streamingEnabled: true, streamingModelDownloaded: true, sttEngine: .whisperKit,
            forcedLanguage: "en", isSecureField: false, hasCollapsedSelection: false,
            hasInsertionTarget: true
        ))
    }

    @Test func shouldStreamLiveStillRequiresEveryOtherGate() {
        let base = (streamingEnabled: true, streamingModelDownloaded: true, sttEngine: STTEngineKind.whisperKit, forcedLanguage: "en", isSecureField: false, hasCollapsedSelection: true, hasInsertionTarget: true)
        #expect(AppCoordinator.shouldStreamLive(
            streamingEnabled: base.streamingEnabled, streamingModelDownloaded: base.streamingModelDownloaded,
            sttEngine: base.sttEngine, forcedLanguage: base.forcedLanguage, isSecureField: base.isSecureField,
            hasCollapsedSelection: base.hasCollapsedSelection, hasInsertionTarget: base.hasInsertionTarget
        ))
        // Secure field still wins even with a collapsed selection.
        #expect(!AppCoordinator.shouldStreamLive(
            streamingEnabled: base.streamingEnabled, streamingModelDownloaded: base.streamingModelDownloaded,
            sttEngine: base.sttEngine, forcedLanguage: base.forcedLanguage, isSecureField: true,
            hasCollapsedSelection: base.hasCollapsedSelection, hasInsertionTarget: base.hasInsertionTarget
        ))
        // Auto-detect (nil forced language) never streams.
        #expect(!AppCoordinator.shouldStreamLive(
            streamingEnabled: base.streamingEnabled, streamingModelDownloaded: base.streamingModelDownloaded,
            sttEngine: base.sttEngine, forcedLanguage: nil, isSecureField: base.isSecureField,
            hasCollapsedSelection: base.hasCollapsedSelection, hasInsertionTarget: base.hasInsertionTarget
        ))
    }

    // MARK: - Findings 2, 3, 5: unverified readback never backspaces

    @Test func finalizeDecisionBackspacesOnlyWhenVerified() {
        let (shouldBackspace, shouldFreeze, outcome) = LiveInsertionSession.finalizeDecision(
            action: .done, refinedText: "refined", rawText: "raw",
            isFrozen: false, ledgerCount: 5, verified: true
        )
        #expect(shouldBackspace)
        #expect(!shouldFreeze)
        #expect(outcome == .insert("refined"))
    }

    @Test func finalizeDecisionRefusesToDeleteOnReadbackMismatch() {
        // A non-empty ledger that fails verification (Codex finding 3: `CGEvent.post` succeeding
        // is not proof of delivery) must never be backspaced — for Done/Raw the refined text
        // instead goes to the clipboard with a HUD hint.
        let (shouldBackspace, shouldFreeze, outcome) = LiveInsertionSession.finalizeDecision(
            action: .done, refinedText: "refined", rawText: "raw",
            isFrozen: false, ledgerCount: 5, verified: false
        )
        #expect(!shouldBackspace)
        #expect(shouldFreeze)
        #expect(outcome == .clipboardOnly("refined"))
    }

    @Test func finalizeDecisionCancelOnMismatchLeavesTypedTextAloneWithoutTouchingClipboard() {
        // Codex finding 2: Cancel's branch previously backspaced unconditionally, before any
        // freshness/verification check. A mismatch on Cancel must leave the typed text on screen
        // (no backspace) AND never touch the clipboard (there is no refined text to offer).
        let (shouldBackspace, shouldFreeze, outcome) = LiveInsertionSession.finalizeDecision(
            action: .cancel, refinedText: "", rawText: "",
            isFrozen: false, ledgerCount: 5, verified: false
        )
        #expect(!shouldBackspace)
        #expect(shouldFreeze)
        #expect(outcome == .none)
    }

    @Test func finalizeDecisionCancelOnVerifiedMatchBackspacesAndInsertsNothing() {
        let (shouldBackspace, shouldFreeze, outcome) = LiveInsertionSession.finalizeDecision(
            action: .cancel, refinedText: "", rawText: "",
            isFrozen: false, ledgerCount: 5, verified: true
        )
        #expect(shouldBackspace)
        #expect(!shouldFreeze)
        #expect(outcome == .none)
    }

    @Test func finalizeDecisionFrozenNeverBackspacesEvenIfLaterVerified() {
        // A frozen session (focus already known to have drifted) must never backspace again,
        // regardless of what `verified` says — the target may be a different window/app entirely.
        let (shouldBackspace, shouldFreeze, outcome) = LiveInsertionSession.finalizeDecision(
            action: .done, refinedText: "refined", rawText: "raw",
            isFrozen: true, ledgerCount: 5, verified: true
        )
        #expect(!shouldBackspace)
        #expect(!shouldFreeze)
        #expect(outcome == .clipboardOnly("refined"))
    }

    @Test func finalizeDecisionEmptyLedgerNeedsNoVerification() {
        // Nothing was ever typed: no destructive action, and `verified` is irrelevant.
        let (shouldBackspace, shouldFreeze, outcome) = LiveInsertionSession.finalizeDecision(
            action: .done, refinedText: "refined", rawText: "raw",
            isFrozen: false, ledgerCount: 0, verified: false
        )
        #expect(!shouldBackspace)
        #expect(!shouldFreeze)
        #expect(outcome == .insert("refined"))
    }

    // MARK: - Finding 7: capture-generation ownership

    @Test func sessionBelongsToCaptureOnlyWhenGenerationsMatch() {
        #expect(AppCoordinator.sessionBelongsToCapture(sessionGeneration: 3, currentGeneration: 3))
        #expect(!AppCoordinator.sessionBelongsToCapture(sessionGeneration: 3, currentGeneration: 4))
    }
}
