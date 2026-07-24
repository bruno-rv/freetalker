import Foundation
import Testing
@testable import FreeTalker

/// Correction Loop (BRAINSTORM_CORRECTION_LOOP.md): pure-logic coverage for the shared
/// evidence/approval path used by all three correction signals. No AX, no CGEvent — those live in
/// the signal-specific call sites (hotkey panel, Voice Edit hook, edit-watcher), which this suite
/// deliberately does not exercise (see the build report for what's covered by AX-live smoke
/// testing instead).
@Suite @MainActor struct CorrectionRecorderTests {
    // MARK: - candidate(wrongText:rightText:) reuses VocabularyMiner's diff, unmodified

    @Test func singleWordSubstitutionProducesACandidate() {
        // Anchored on both sides ("hi" before, "how" after) — see VocabularyMiner's own
        // "replacementAtTheEndOfTheTranscriptProducesNoCandidateBecauseItHasNoRightAnchor".
        let candidate = CorrectionRecorder.candidate(wrongText: "hi joao how are you", rightText: "hi João how are you")
        #expect(candidate?.normalizedTerm == "joão")
        #expect(candidate?.surfaceTerm == "João")
        #expect(candidate?.source == .userSupplied)
    }

    @Test func wholeSentenceRewriteProducesNoCandidate() {
        // No anchoring context on either side of a total rewrite — VocabularyMiner's own
        // "anchored local substitution" contract, reused here unmodified.
        #expect(CorrectionRecorder.candidate(wrongText: "hello there friend", rightText: "good morning pal") == nil)
    }

    @Test func identicalTextProducesNoCandidate() {
        #expect(CorrectionRecorder.candidate(wrongText: "hi João how are you", rightText: "hi João how are you") == nil)
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
