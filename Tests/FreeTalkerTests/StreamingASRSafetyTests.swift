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

    // MARK: - Round 2 finding 1: tri-state secure-field check fails closed on doubt

    @Test func secureCheckResultRefusesOnUnreadableSubrole() {
        // A password field returning `.cannotComplete` (unreadable) while its protected-content
        // read still succeeds must be treated as unsafe, not "not secure" — the old `Bool`
        // collapse silently turned any AX error into `false` (fail OPEN); this must fail closed.
        #expect(Insertion.secureCheckResult(subrole: .unreadable, protectedContent: .value(false)) == .unreadable)
    }

    @Test func secureCheckResultRefusesOnUnreadableProtectedContent() {
        #expect(Insertion.secureCheckResult(subrole: .absent, protectedContent: .unreadable) == .unreadable)
    }

    @Test func secureCheckResultAffirmativeNotSecureRequiresBothReadsToResolve() {
        // A legitimately absent subrole (the control doesn't expose one at all — most ordinary
        // text fields) contributes "not secure via subrole", not doubt — otherwise streaming
        // could never start on any plain text field.
        #expect(Insertion.secureCheckResult(subrole: .absent, protectedContent: .value(false)) == .notSecure)
        #expect(Insertion.secureCheckResult(subrole: .value("AXTextField"), protectedContent: .value(false)) == .notSecure)
    }

    @Test func secureCheckResultDetectsAffirmativelySecureFields() {
        #expect(Insertion.secureCheckResult(subrole: .value("AXSecureTextField"), protectedContent: .value(false)) == .secure)
        #expect(Insertion.secureCheckResult(subrole: .absent, protectedContent: .value(true)) == .secure)
    }

    // MARK: - Round 2 finding 2: per-partial collapsed-selection + caret requirement

    @MainActor
    @Test func receivePartialFreezesWithoutTypingWhenSelectionOrCaretCheckFails() {
        // `writeSnapshotCaret` returning nil simulates the fresh read finding a non-collapsed
        // selection (or a drifted/unsafe target) — must freeze WITHOUT ever reaching the real
        // CGEvent-posting `typeText`, so nothing is typed over whatever the user just selected.
        let target = InsertionTarget(bundleID: "com.test.app", pid: 1, focusedElement: nil, window: nil)
        let session = LiveInsertionSession(
            target: target,
            generation: 1,
            writeSnapshotCaret: { _, _ in nil },
            verifyBeforeDelete: { _, _, _ in false }
        )
        session.receivePartial("hello")
        #expect(session.ledger.isEmpty)
        #expect(session.isFrozen)
    }

    @MainActor
    @Test func receivePartialChecksSelectionEvenOnTheVeryFirstPostWithAnEmptyLedger() {
        // The first partial has no caret anchor yet (ledger empty) — the fresh-read check must
        // still run (with `expectedCaret == nil`, since there's no anchor yet) rather than being
        // skipped entirely just because nothing has been typed yet.
        var wasCalled = false
        var observedExpectedCaret: Int? = -1 // sentinel distinguishable from the expected nil
        let target = InsertionTarget(bundleID: "com.test.app", pid: 1, focusedElement: nil, window: nil)
        let session = LiveInsertionSession(
            target: target,
            generation: 1,
            writeSnapshotCaret: { _, expectedCaret in
                wasCalled = true
                observedExpectedCaret = expectedCaret
                return nil // still unsafe/unreadable in this test — no real CGEvent posted
            },
            verifyBeforeDelete: { _, _, _ in false }
        )
        session.receivePartial("hi")
        #expect(wasCalled)
        #expect(observedExpectedCaret == nil)
        #expect(session.isFrozen)
    }

    // MARK: - Round 2 finding 3: caret-anchor mismatch refuses to delete

    @Test func verificationOutcomeFailsClosedWhenLedgerNonEmptyButNoAnchorExists() {
        // Invariant violation (the anchor is always set alongside the ledger's first growth) —
        // never trust an unverifiable state.
        #expect(!LiveInsertionSession.verificationOutcome(ledgerIsEmpty: false, hasCaretAnchor: false, readbackMatches: true))
    }

    @Test func verificationOutcomeRequiresTheCaretReadbackToMatchWhenAnchorExists() {
        // Codex finding 3: content matching alone is not enough — the caller's `readbackMatches`
        // already folds in the absolute caret-anchor check (not just "some matching text sits
        // before wherever the caret currently is"), and a mismatch there must refuse deletion.
        #expect(LiveInsertionSession.verificationOutcome(ledgerIsEmpty: false, hasCaretAnchor: true, readbackMatches: true))
        #expect(!LiveInsertionSession.verificationOutcome(ledgerIsEmpty: false, hasCaretAnchor: true, readbackMatches: false))
    }

    @Test func verificationOutcomeEmptyLedgerNeedsNoAnchorOrReadback() {
        #expect(LiveInsertionSession.verificationOutcome(ledgerIsEmpty: true, hasCaretAnchor: false, readbackMatches: false))
    }

    // MARK: - Round 2 finding 4: stale epoch rejection

    @Test func shouldProcessRawPartialRejectsAnEpochFromABeforeSessionThatHasSinceMovedOn() {
        // A raw partial's handoff `Task` captures the epoch live at `setPartialCallback`
        // registration time; if `start`/`reset`/`unload` bumped the epoch by the time that Task
        // actually runs (a later session took over the shared engine), it must be dropped rather
        // than delivered against the new session's state.
        #expect(FluidAudioStreamingEngine.shouldProcessRawPartial(capturedEpoch: 1, currentEpoch: 1))
        #expect(!FluidAudioStreamingEngine.shouldProcessRawPartial(capturedEpoch: 1, currentEpoch: 2))
    }
}
