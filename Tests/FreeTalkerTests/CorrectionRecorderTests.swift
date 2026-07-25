import Foundation
import Testing
@testable import FreeTalker

/// Correction Loop (BRAINSTORM_CORRECTION_LOOP.md): pure-logic coverage for the shared
/// evidence/approval path used by all three correction signals. No AX, no CGEvent — those live in
/// the signal-specific call sites (hotkey panel, Voice Edit hook, edit-watcher), which this suite
/// deliberately does not exercise (see the build report for what's covered by AX-live smoke
/// testing instead).
@Suite @MainActor struct CorrectionRecorderTests {
    // MARK: - candidate(wrongText:rightText:)/correctionSubstitution: Codex finding 7 —
    // deliberate corrections are NOT filtered through VocabularyMiner's anchor-position/
    // minimum-length/edit-distance guess-filtering heuristics.

    @Test func singleWordSubstitutionProducesACandidate() {
        let candidate = CorrectionRecorder.candidate(wrongText: "hi joao how are you", rightText: "hi João how are you")
        #expect(candidate?.normalizedTerm == "joão")
        #expect(candidate?.surfaceTerm == "João")
        #expect(candidate?.source == .userSupplied)
    }

    @Test func wholeSentenceRewriteProducesNoCandidate() {
        // Three changed tokens, not a single anchored substitution — still out of scope
        // (BRAINSTORM_CORRECTION_LOOP.md: "single misheard words and names," not phrases).
        #expect(CorrectionRecorder.candidate(wrongText: "hello there friend", rightText: "good morning pal") == nil)
    }

    @Test func identicalTextProducesNoCandidate() {
        #expect(CorrectionRecorder.candidate(wrongText: "hi João how are you", rightText: "hi João how are you") == nil)
    }

    /// Codex finding 7: a correction at the very FIRST word — no left anchor at all — is exactly
    /// what `VocabularyMiner.candidates` would reject (`hasLeftAnchor == false`), but a deliberate
    /// user correction here must still be learned.
    @Test func correctionAtTheFirstWordWithNoLeftAnchorProducesACandidate() {
        let candidate = CorrectionRecorder.candidate(wrongText: "joao how are you", rightText: "João how are you")
        #expect(candidate?.normalizedTerm == "joão")
        #expect(candidate?.surfaceTerm == "João")
    }

    /// Codex finding 7: a correction at the very LAST word — no right anchor — is exactly what
    /// `VocabularyMiner.candidates` would reject (`hasRightAnchor == false`).
    @Test func correctionAtTheLastWordWithNoRightAnchorProducesACandidate() {
        let candidate = CorrectionRecorder.candidate(wrongText: "meet with joao", rightText: "meet with João")
        #expect(candidate?.normalizedTerm == "joão")
        #expect(candidate?.surfaceTerm == "João")
    }

    /// Codex finding 7: a term shorter than `VocabularyMiner.minTermLength` (4) is exactly what
    /// the miner would reject as too noisy a signal to trust unattributed — a deliberate
    /// correction has no such ambiguity.
    @Test func correctionOfATermShorterThanTheMinersMinimumLengthProducesACandidate() {
        let candidate = CorrectionRecorder.candidate(wrongText: "call me sam", rightText: "call me Sal")
        #expect(candidate?.normalizedTerm == "sal")
        #expect(candidate?.surfaceTerm == "Sal")
    }

    /// Codex finding 7: an edit distance above `VocabularyMiner.maxEditDistance` (2) is exactly
    /// what the miner would reject as "probably an unrelated word, not a spelling fix" — a
    /// deliberate correction proves it's the same word regardless of how different the spellings
    /// end up looking.
    @Test func correctionWithEditDistanceAboveTheMinersMaximumProducesACandidate() {
        let candidate = CorrectionRecorder.candidate(wrongText: "deploy to wrongword now", rightText: "deploy to RightTerm now")
        #expect(candidate?.normalizedTerm == "rightterm")
        #expect(candidate?.surfaceTerm == "RightTerm")
    }

    /// `VocabularyMiner` itself is unchanged by finding 7's fix — its own anchoring/length/edit-
    /// distance heuristics still apply to MINED (unattributed) evidence.
    @Test func vocabularyMinerItselfStillRejectsFirstWordCorrectionsForMinedEvidence() {
        #expect(VocabularyMiner.candidates(transcript: "joao how are you", refined: "João how are you").isEmpty)
    }

    // MARK: - decide(...) pure decision core

    @Test func noExistingDecisionAndFitsIsApprovedImmediately() {
        let outcome = CorrectionRecorder.decide(
            existingStatus: nil, confirmDismissedOverride: false, fits: true, confirmSwap: false,
            swapCandidateNormalized: nil, swapCandidateSurface: nil, surfaceTerm: "João"
        )
        #expect(outcome == .approved)
    }

    @Test func alreadyApprovedIsANoOp() {
        let outcome = CorrectionRecorder.decide(
            existingStatus: .approved, confirmDismissedOverride: false, fits: true, confirmSwap: false,
            swapCandidateNormalized: nil, swapCandidateSurface: nil, surfaceTerm: "João"
        )
        #expect(outcome == .alreadyApproved)
    }

    /// Requirement 10: "a previously dismissed suggestion must not silently return through a
    /// correction path."
    @Test func previouslyDismissedRequiresExplicitConfirmationRatherThanSilentlyReturning() {
        let outcome = CorrectionRecorder.decide(
            existingStatus: .dismissed, confirmDismissedOverride: false, fits: true, confirmSwap: false,
            swapCandidateNormalized: nil, swapCandidateSurface: nil, surfaceTerm: "João"
        )
        #expect(outcome == .needsDismissalConfirmation(surfaceTerm: "João"))
    }

    @Test func previouslyDismissedWithExplicitOverrideAndFitsIsApproved() {
        let outcome = CorrectionRecorder.decide(
            existingStatus: .dismissed, confirmDismissedOverride: true, fits: true, confirmSwap: false,
            swapCandidateNormalized: nil, swapCandidateSurface: nil, surfaceTerm: "João"
        )
        #expect(outcome == .approved)
    }

    /// Requirement 5: "when the vocabulary budget is full, offer to drop the least-used term...
    /// never evicts silently."
    @Test func budgetFullOffersASwapRatherThanEvictingOrRefusingOutright() {
        let outcome = CorrectionRecorder.decide(
            existingStatus: nil, confirmDismissedOverride: false, fits: false, confirmSwap: false,
            swapCandidateNormalized: "oldterm", swapCandidateSurface: "OldTerm", surfaceTerm: "João"
        )
        #expect(outcome == .budgetFull(swapCandidateNormalized: "oldterm", swapCandidateSurface: "OldTerm", newTermSurface: "João"))
    }

    @Test func budgetFullWithNoSwapCandidateStillNeverAutoApproves() {
        // Nothing approved to swap out (the user's OWN manual vocabulary alone fills the budget)
        // — still refuses rather than approving anyway.
        let outcome = CorrectionRecorder.decide(
            existingStatus: nil, confirmDismissedOverride: false, fits: false, confirmSwap: false,
            swapCandidateNormalized: nil, swapCandidateSurface: nil, surfaceTerm: "João"
        )
        #expect(outcome == .budgetFull(swapCandidateNormalized: "", swapCandidateSurface: "", newTermSurface: "João"))
    }

    @Test func confirmedSwapApproves() {
        let outcome = CorrectionRecorder.decide(
            existingStatus: nil, confirmDismissedOverride: false, fits: false, confirmSwap: true,
            swapCandidateNormalized: "oldterm", swapCandidateSurface: "OldTerm", surfaceTerm: "João"
        )
        #expect(outcome == .approved)
    }

    /// Codex Round 2 finding 4: the panel freezes the swap candidate a `.budgetFull` offer NAMED
    /// (`expectedSwapNormalizedTerm`) — a Swap click re-confirms THAT exact term. If the
    /// vocabulary state moved on between the offer and the click (e.g. the offered term was
    /// dismissed via Settings, so `swapCandidateNormalized` now recomputes to a DIFFERENT,
    /// newer-oldest term), the swap must be refused rather than silently dropping the different
    /// term — falls through to a fresh `.budgetFull` naming the CURRENT candidate instead.
    @Test func confirmSwapWhoseExpectedCandidateNoLongerMatchesProducesANewOfferRatherThanDroppingADifferentTerm() {
        let outcome = CorrectionRecorder.decide(
            existingStatus: nil, confirmDismissedOverride: false, fits: false, confirmSwap: true,
            swapCandidateNormalized: "newoldest", swapCandidateSurface: "NewOldest", surfaceTerm: "João",
            expectedSwapNormalizedTerm: "originallyoffered"
        )
        #expect(outcome == .budgetFull(swapCandidateNormalized: "newoldest", swapCandidateSurface: "NewOldest", newTermSurface: "João"))
    }

    /// The matching case (the frozen candidate is STILL what's currently computed) proceeds
    /// exactly as `confirmedSwapApproves` above — `expectedSwapNormalizedTerm` only ever refuses a
    /// MISMATCH, never blocks an unchanged offer.
    @Test func confirmSwapWhoseExpectedCandidateStillMatchesApproves() {
        let outcome = CorrectionRecorder.decide(
            existingStatus: nil, confirmDismissedOverride: false, fits: false, confirmSwap: true,
            swapCandidateNormalized: "oldterm", swapCandidateSurface: "OldTerm", surfaceTerm: "João",
            expectedSwapNormalizedTerm: "oldterm"
        )
        #expect(outcome == .approved)
    }

    @Test func confirmSwapWithoutANamedCandidateStillRefuses() {
        // `confirmSwap: true` with nothing to swap (race: the swap candidate got dismissed by
        // something else between the offer and this confirmation) must not fall through to an
        // approval with no corresponding eviction.
        let outcome = CorrectionRecorder.decide(
            existingStatus: nil, confirmDismissedOverride: false, fits: false, confirmSwap: true,
            swapCandidateNormalized: nil, swapCandidateSurface: nil, surfaceTerm: "João"
        )
        #expect(outcome == .budgetFull(swapCandidateNormalized: "", swapCandidateSurface: "", newTermSurface: "João"))
    }

    // MARK: - record(...) end-to-end (VocabStore + AppSettings, no AX)

    @Test func recordApprovesImmediatelyWithoutWaitingForRecurrence() async throws {
        let url = temporaryDatabaseURL()
        let library = try Database(path: url)
        let id = try library.insertDictation(makeInsertRequest(transcript: "hi joao how are you", refined: "hi João how are you"))
        let store = try VocabStore(databaseURL: url)
        let settings = makeSettings()

        // A single evidence row — VocabStore.minimumRecurrence (2) would never surface this as a
        // suggestion, but a deliberate correction doesn't wait in that queue (requirement 8).
        let outcome = try await CorrectionRecorder.record(
            dictationID: id, wrongText: "hi joao how are you", rightText: "hi João how are you", store: store, settings: settings
        )
        #expect(outcome == .approved)
        #expect(try await store.approvedTerms().map(\.normalizedTerm) == ["joão"])
        #expect(try await store.evidenceSources(normalizedTerm: "joão") == [.userSupplied])
    }

    @Test func recordDoesNotOverrideAPreviousDismissalWithoutConfirmation() async throws {
        let url = temporaryDatabaseURL()
        let library = try Database(path: url)
        let id = try library.insertDictation(makeInsertRequest(transcript: "hi joao how are you", refined: "hi João how are you"))
        let store = try VocabStore(databaseURL: url)
        _ = try await store.dismiss(normalizedTerm: "joão")
        let settings = makeSettings()

        let outcome = try await CorrectionRecorder.record(
            dictationID: id, wrongText: "hi joao how are you", rightText: "hi João how are you", store: store, settings: settings
        )
        #expect(outcome == .needsDismissalConfirmation(surfaceTerm: "João"))
        #expect(try await store.approvedTerms().isEmpty)

        let confirmed = try await CorrectionRecorder.record(
            dictationID: id, wrongText: "hi joao how are you", rightText: "hi João how are you", store: store, settings: settings,
            confirmDismissedOverride: true
        )
        #expect(confirmed == .approved)
        #expect(try await store.approvedTerms().map(\.normalizedTerm) == ["joão"])
    }

    @Test func recordOffersASwapWhenTheBudgetIsFullThenAppliesItOnlyOnConfirmation() async throws {
        let url = temporaryDatabaseURL()
        let library = try Database(path: url)
        // "kubernettes" -> "kubernetes": edit distance 1, anchored on both sides — a genuine mishearing,
        // not the unrelated-word pair `wrongword`/`RightWord` (edit distance well above
        // VocabularyMiner.maxEditDistance, which produced no candidate at all here originally).
        let id = try library.insertDictation(makeInsertRequest(transcript: "hi kubernettes how are you", refined: "hi kubernetes how are you"))
        let store = try VocabStore(databaseURL: url)
        let settings = makeSettings()

        // Two already-approved terms, each under `AppSettings.maxVocabularyTermLength` (50 bytes,
        // a single term any longer is dropped by validation, never counted toward the budget) but
        // together consuming almost all of `VocabularyFitGate.tokenBudget` (111 bytes: " " + 50
        // + ", " + 50 = 103), so a third ~9-byte term never fits alongside both.
        let filler1 = String(repeating: "a", count: 50)
        let filler2 = String(repeating: "b", count: 50)
        _ = try await store.mergeDecisions([
            VocabDecision(normalizedTerm: filler1.lowercased(), status: .approved, surfaceTerm: filler1, decidedAt: Date(timeIntervalSince1970: 100)),
            VocabDecision(normalizedTerm: filler2.lowercased(), status: .approved, surfaceTerm: filler2, decidedAt: Date(timeIntervalSince1970: 200))
        ])
        settings.applyApprovedVocabularyCache(try await store.approvedTerms())

        let outcome = try await CorrectionRecorder.record(
            dictationID: id, wrongText: "hi kubernettes how are you", rightText: "hi kubernetes how are you", store: store, settings: settings
        )
        guard case .budgetFull(let swapNormalized, _, let newTerm) = outcome else {
            Issue.record("expected .budgetFull, got \(outcome)")
            return
        }
        // Least-used = oldest approved among the currently-active set — filler1, not filler2.
        #expect(swapNormalized == filler1.lowercased())
        #expect(newTerm == "kubernetes")
        // Never evicted silently — both filler terms are still approved after the mere OFFER.
        #expect(try await store.approvedTerms().map(\.normalizedTerm) == [filler1.lowercased(), filler2.lowercased()])

        let confirmed = try await CorrectionRecorder.record(
            dictationID: id, wrongText: "hi kubernettes how are you", rightText: "hi kubernetes how are you", store: store, settings: settings,
            confirmSwap: true
        )
        #expect(confirmed == .approved)
        // filler1 dismissed (the swap), filler2 untouched, kubernetes newly approved.
        #expect(try await store.approvedTerms().map(\.normalizedTerm) == [filler2.lowercased(), "kubernetes"])
    }

    /// Codex Round 2 finding 4, end-to-end: the panel offers "Drop filler1 to learn <newTerm>."
    /// Before the user clicks Swap, filler1 is dismissed via Settings (a completely independent
    /// write) — the oldest still-ACTIVE approved term is now filler2. The Swap confirmation must
    /// refuse to drop filler2 (consent never named it) and instead surface a fresh offer for it.
    ///
    /// Byte budget arithmetic (`VocabularyFitGate.tokenBudget` ~111 bytes, see that type):
    /// three 35-byte fillers together cost 3*35 + 4 = 109 bytes (all three fit, so `activeApproved`
    /// includes all three and the offer names the OLDEST, filler1) but adding the 45-byte new term
    /// on top costs 109 + 45 + 2 = 156 (never fits, whether all three fillers are present or just
    /// the two that remain once filler1 is dismissed: 2*35 + 2 + 45 + 2 = 119, still over budget)
    /// — the new term stays displaced (offered as a swap) in BOTH states, only WHICH term is the
    /// current oldest changes.
    @Test func recordRefusesToSwapADifferentTermThanTheOneTheFrozenOfferNamed() async throws {
        let url = temporaryDatabaseURL()
        let library = try Database(path: url)
        let id = try library.insertDictation(makeInsertRequest(transcript: "hi wrongtermxx how are you", refined: "hi rightterm how are you"))
        let store = try VocabStore(databaseURL: url)
        let settings = makeSettings()

        let filler1 = String(repeating: "a", count: 35)
        let filler2 = String(repeating: "b", count: 35)
        let filler3 = String(repeating: "c", count: 35)
        _ = try await store.mergeDecisions([
            VocabDecision(normalizedTerm: filler1.lowercased(), status: .approved, surfaceTerm: filler1, decidedAt: Date(timeIntervalSince1970: 100)),
            VocabDecision(normalizedTerm: filler2.lowercased(), status: .approved, surfaceTerm: filler2, decidedAt: Date(timeIntervalSince1970: 200)),
            VocabDecision(normalizedTerm: filler3.lowercased(), status: .approved, surfaceTerm: filler3, decidedAt: Date(timeIntervalSince1970: 300))
        ])
        settings.applyApprovedVocabularyCache(try await store.approvedTerms())

        let rightTerm = String(repeating: "d", count: 45)
        let offer = try await CorrectionRecorder.record(
            dictationID: id, wrongText: "hi wrongtermxx how are you", rightText: "hi \(rightTerm) how are you", store: store, settings: settings
        )
        guard case .budgetFull(let offeredSwap, _, _) = offer else {
            Issue.record("expected .budgetFull, got \(offer)")
            return
        }
        #expect(offeredSwap == filler1.lowercased())

        // Independent write: filler1 dismissed via Settings between the offer and the Swap click.
        _ = try await store.dismiss(normalizedTerm: filler1.lowercased())
        settings.applyApprovedVocabularyCache(try await store.approvedTerms())

        let confirmed = try await CorrectionRecorder.record(
            dictationID: id, wrongText: "hi wrongtermxx how are you", rightText: "hi \(rightTerm) how are you", store: store, settings: settings,
            confirmSwap: true, expectedSwapNormalizedTerm: offeredSwap
        )
        guard case .budgetFull(let newSwap, _, _) = confirmed else {
            Issue.record("expected a NEW .budgetFull naming the current candidate, got \(confirmed)")
            return
        }
        #expect(newSwap == filler2.lowercased())
        // filler2/filler3 must still be approved — never silently dropped for a consent that
        // named filler1 — and the new term never approved either.
        #expect(try await store.approvedTerms().map(\.normalizedTerm) == [filler2.lowercased(), filler3.lowercased()])
        #expect(try await store.decision(normalizedTerm: rightTerm.lowercased()) == nil)
    }

    @Test func recordOnAnAlreadyApprovedTermIsANoOp() async throws {
        let url = temporaryDatabaseURL()
        let library = try Database(path: url)
        let id = try library.insertDictation(makeInsertRequest(transcript: "hi joao how are you", refined: "hi João how are you"))
        let store = try VocabStore(databaseURL: url)
        // approve() needs at least one evidence row to fix the canonical spelling from — provide
        // one via a prior mined sighting, distinct from this test's user-supplied recording.
        try await store.recordEvidence(dictationID: id, candidates: [VocabEvidenceCandidate(normalizedTerm: "joão", surfaceTerm: "João")])
        _ = try await store.approve(normalizedTerm: "joão")
        let settings = makeSettings()

        let outcome = try await CorrectionRecorder.record(
            dictationID: id, wrongText: "hi joao how are you", rightText: "hi João how are you", store: store, settings: settings
        )
        #expect(outcome == .alreadyApproved)
    }

    @Test func recordWithNoWrongRightPairRecordsNothing() async throws {
        let url = temporaryDatabaseURL()
        let library = try Database(path: url)
        let id = try library.insertDictation(makeInsertRequest(transcript: "same", refined: "same"))
        let store = try VocabStore(databaseURL: url)
        let settings = makeSettings()

        let outcome = try await CorrectionRecorder.record(
            dictationID: id, wrongText: "same", rightText: "same", store: store, settings: settings
        )
        #expect(outcome == .noWrongRightPair)
        #expect(try await store.suggestions(minimumRecurrence: 1, limit: 25).isEmpty)
    }
}

@MainActor
private func makeSettings() -> AppSettings {
    let suite = "CorrectionRecorderTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return AppSettings(defaults: defaults)
}

private func makeInsertRequest(transcript: String, refined: String) -> DictationInsertRequest {
    .init(
        timestamp: Date(), sourceLanguage: SourceLanguage("en"),
        requestedOutputLanguage: .sameAsSpoken, template: "Clean",
        transcript: transcript, refined: refined, engine: "local",
        voiceCommandsActive: false
    )
}

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("sqlite")
}
