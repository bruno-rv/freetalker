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
            isFrozen: false, ledgerCount: 5, verified: true, emptyLedgerInsertSafe: true
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
            isFrozen: false, ledgerCount: 5, verified: false, emptyLedgerInsertSafe: true
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
            isFrozen: false, ledgerCount: 5, verified: false, emptyLedgerInsertSafe: true
        )
        #expect(!shouldBackspace)
        #expect(shouldFreeze)
        #expect(outcome == .none)
    }

    @Test func finalizeDecisionCancelOnVerifiedMatchBackspacesAndInsertsNothing() {
        let (shouldBackspace, shouldFreeze, outcome) = LiveInsertionSession.finalizeDecision(
            action: .cancel, refinedText: "", rawText: "",
            isFrozen: false, ledgerCount: 5, verified: true, emptyLedgerInsertSafe: true
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
            isFrozen: true, ledgerCount: 5, verified: true, emptyLedgerInsertSafe: true
        )
        #expect(!shouldBackspace)
        #expect(!shouldFreeze)
        #expect(outcome == .clipboardOnly("refined"))
    }

    @Test func finalizeDecisionEmptyLedgerNeedsNoBackspaceVerificationButStillNeedsTheFreshInsertCheck() {
        // Nothing was ever typed: no destructive backspace, so `verified` is irrelevant — but
        // (Codex round 3 finding 1) `.insert` is still gated on the caller's fresh
        // collapsed-selection/secure/identity check.
        let (shouldBackspace, shouldFreeze, outcome) = LiveInsertionSession.finalizeDecision(
            action: .done, refinedText: "refined", rawText: "raw",
            isFrozen: false, ledgerCount: 0, verified: false, emptyLedgerInsertSafe: true
        )
        #expect(!shouldBackspace)
        #expect(!shouldFreeze)
        #expect(outcome == .insert("refined"))
    }

    @Test func finalizeDecisionEmptyLedgerFallsBackToClipboardWhenTheFreshInsertCheckFails() {
        // Codex round 3 finding 1: an empty ledger previously took the `.insert` branch
        // unconditionally — no destructive backspace, but `.insert` still performs the session's
        // only OTHER consequential action (an ordinary pasteboard paste) with none of the
        // streaming security checks. When the caller's fresh check fails (a selection is present,
        // the target drifted, or the field turned secure), this must fall back to clipboard-only,
        // same as an unverified non-empty ledger — and never backspace (there's nothing to).
        let (shouldBackspace, shouldFreeze, outcome) = LiveInsertionSession.finalizeDecision(
            action: .done, refinedText: "refined", rawText: "raw",
            isFrozen: false, ledgerCount: 0, verified: false, emptyLedgerInsertSafe: false
        )
        #expect(!shouldBackspace)
        #expect(!shouldFreeze)
        #expect(outcome == .clipboardOnly("refined"))
    }

    @Test func finalizeDecisionEmptyLedgerCancelIgnoresTheFreshInsertCheck() {
        // Cancel with nothing typed has nothing to insert regardless of the fresh check's result.
        let (shouldBackspace, shouldFreeze, outcome) = LiveInsertionSession.finalizeDecision(
            action: .cancel, refinedText: "", rawText: "",
            isFrozen: false, ledgerCount: 0, verified: false, emptyLedgerInsertSafe: false
        )
        #expect(!shouldBackspace)
        #expect(!shouldFreeze)
        #expect(outcome == .none)
    }

    // MARK: - Round 3 finding 1: `finalize()` performs the fresh empty-ledger check itself

    @MainActor
    @Test func finalizeWithEmptyLedgerRequiresAFreshCollapsedCaretCheckBeforeInserting() {
        // Nothing was ever typed (`receivePartial` never called, ledger stays empty) — `finalize`
        // must still call `writeSnapshotCaret` with `expectedCaret: nil` (a fresh
        // collapsed-selection/secure/identity read) before accepting `.insert`.
        var writeSnapshotCaretCalls: [Int?] = []
        let target = InsertionTarget(bundleID: "com.test.app", pid: 1, focusedElement: nil, window: nil)
        let session = LiveInsertionSession(
            target: target,
            generation: 1,
            writeSnapshotCaret: { _, expectedCaret in
                writeSnapshotCaretCalls.append(expectedCaret)
                return 0
            },
            readBaselineValue: { _ in "" },
            verifyBeforeDelete: { _, _, _, _ in false }
        )
        let outcome = session.finalize(action: .done, refinedText: "refined", rawText: "refined")
        #expect(writeSnapshotCaretCalls == [nil])
        #expect(outcome == .insert("refined"))
    }

    @MainActor
    @Test func finalizeWithEmptyLedgerFallsBackToClipboardWhenTheFreshCheckFails() {
        // The fresh check finds a real selection, a drifted target, or a now-secure field — the
        // empty-ledger `.insert` must never be taken; the refined text goes to the clipboard
        // instead. This is the exact scenario Codex round 3 finding 1 found unguarded: the user
        // selected pre-existing text before stopping, or the field turned secure mid-Recording,
        // and the OLD code pasted straight over it with no check at all.
        let target = InsertionTarget(bundleID: "com.test.app", pid: 1, focusedElement: nil, window: nil)
        let session = LiveInsertionSession(
            target: target,
            generation: 1,
            writeSnapshotCaret: { _, _ in nil },
            readBaselineValue: { _ in "" },
            verifyBeforeDelete: { _, _, _, _ in false }
        )
        let outcome = session.finalize(action: .done, refinedText: "refined", rawText: "refined")
        #expect(outcome == .clipboardOnly("refined"))
    }

    @MainActor
    @Test func finalizeWithEmptyLedgerOnCancelNeverConsultsTheFreshCheck() {
        // Cancel with nothing typed has nothing to insert either way — must stay `.none` without
        // even performing the (unnecessary) fresh AX read.
        var writeSnapshotCaretCalled = false
        let target = InsertionTarget(bundleID: "com.test.app", pid: 1, focusedElement: nil, window: nil)
        let session = LiveInsertionSession(
            target: target,
            generation: 1,
            writeSnapshotCaret: { _, _ in
                writeSnapshotCaretCalled = true
                return nil
            },
            readBaselineValue: { _ in "" },
            verifyBeforeDelete: { _, _, _, _ in false }
        )
        let outcome = session.finalize(action: .cancel, refinedText: "", rawText: "")
        #expect(!writeSnapshotCaretCalled)
        #expect(outcome == .none)
    }

    // MARK: - Round 3 finding 2: the anchor authenticates provenance, not just location

    @Test func documentMatchesBaselinePlusLedgerAcceptsAnExactReconstruction() {
        let baseline = Array("Dear Sir, . Best regards".utf16)
        let ledger = Array("hello".utf16)
        let anchor = "Dear Sir, ".utf16.count
        let current = Array("Dear Sir, hello. Best regards".utf16)
        #expect(Insertion.documentMatchesBaselinePlusLedger(current: current, baseline: baseline, ledger: ledger, anchor: anchor))
    }

    @Test func documentMatchesBaselinePlusLedgerRefusesPreExistingTextThatOnlyMatchesByLocation() {
        // Codex round 3 finding 2: the field already contains "hello" at offset 0 (the baseline).
        // This session's own synthesized "hello" at offset 0 is silently swallowed by the
        // app/IME — the real document never changes — and the user later parks the caret at
        // offset 5, right after that pre-existing "hello". The OLD check (trailing text before
        // the caret) would have accepted this: "hello" sits right before a caret at 5. The
        // reconstruction check correctly refuses: baseline ("hello") with the ledger ("hello")
        // spliced in at anchor 0 is "hellohello", which does not match what's actually on screen
        // ("hello").
        let baseline = Array("hello".utf16)
        let ledger = Array("hello".utf16)
        let current = Array("hello".utf16)
        #expect(!Insertion.documentMatchesBaselinePlusLedger(current: current, baseline: baseline, ledger: ledger, anchor: 0))
    }

    @Test func documentMatchesBaselinePlusLedgerRefusesAnOutOfBoundsAnchor() {
        // A caret-anchor arithmetic impossibility (should be unreachable in practice) fails
        // closed rather than trapping on the array slice.
        let baseline = Array("hi".utf16)
        let ledger = Array("x".utf16)
        #expect(!Insertion.documentMatchesBaselinePlusLedger(current: baseline, baseline: baseline, ledger: ledger, anchor: 99))
        #expect(!Insertion.documentMatchesBaselinePlusLedger(current: baseline, baseline: baseline, ledger: ledger, anchor: -1))
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
            verifyBeforeDelete: { _, _, _, _ in false }
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
            verifyBeforeDelete: { _, _, _, _ in false }
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

    // MARK: - Round 3 finding 6: the model store leaves its transitional phase before refresh

    @Test func shouldApplyRefreshLeavesTransitionalPhasesAloneWithoutForce() {
        // An ordinary (ambient) refresh — e.g. `SettingsView`'s `.onAppear` — must never write
        // over `.downloading`/`.busy`: a stale refresh that was already in flight when a NEW
        // download/delete operation grabbed the model must not clobber that operation's phase.
        #expect(!StreamingModelStore.shouldApplyRefresh(phase: .downloading(0.5), force: false))
        #expect(!StreamingModelStore.shouldApplyRefresh(phase: .busy(reloadTarget: "parakeet-eou-160ms"), force: false))
    }

    @Test func shouldApplyRefreshProceedsOnOrdinaryNonTransitionalPhases() {
        #expect(StreamingModelStore.shouldApplyRefresh(phase: .notDownloaded, force: false))
        #expect(StreamingModelStore.shouldApplyRefresh(phase: .downloaded, force: false))
        #expect(StreamingModelStore.shouldApplyRefresh(phase: .failed("boom"), force: false))
    }

    @Test func shouldApplyRefreshForcedByTheOwningOperationLeavesTheTransitionalPhase() {
        // Codex round 3 finding 6: `download()`/`delete()` never left `.downloading`/`.busy`
        // before calling their own closing `refresh()` — the ordinary transitional-phase guard
        // bounced it every time, leaving the UI stuck on "Downloading…"/"Loading…" forever. The
        // operation-owned `force: true` refresh must actually proceed past its own phase.
        #expect(StreamingModelStore.shouldApplyRefresh(phase: .downloading(1.0), force: true))
        #expect(StreamingModelStore.shouldApplyRefresh(phase: .busy(reloadTarget: "parakeet-eou-160ms"), force: true))
        #expect(StreamingModelStore.shouldApplyRefresh(phase: .downloaded, force: true))
    }
}
