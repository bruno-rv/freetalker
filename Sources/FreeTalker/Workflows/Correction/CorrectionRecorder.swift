import Foundation

/// Shared entry point for all three Correction Loop signals (hotkey panel, spoken correction,
/// edit-watcher — BRAINSTORM_CORRECTION_LOOP.md "Shared core", item 2): turns a wrong→right pair
/// tied to a specific dictation into vocabulary evidence, marked user-supplied, and — unlike the
/// mined-suggestion queue — applies it immediately rather than waiting for `VocabStore.
/// minimumRecurrence`. Pure orchestration over `VocabStore`/`AppSettings`/`EffectiveVocabulary`;
/// the three signals each locate/verify/repair the live text themselves (AX, CGEvent) and call
/// this only once a correction is confirmed.
enum CorrectionRecorder {
    enum Outcome: Equatable {
        /// Recorded as evidence and approved immediately — active right away (requirement 8).
        case approved
        /// Evidence recorded; the term was already approved — no change needed.
        case alreadyApproved
        /// Evidence recorded, but this term was previously DISMISSED as a suggestion — approval
        /// is withheld until the caller explicitly re-confirms (requirement 10: "a previously
        /// dismissed suggestion must not silently return through a correction path"). Re-invoke
        /// `record` with `confirmDismissedOverride: true` to proceed.
        case needsDismissalConfirmation(surfaceTerm: String)
        /// The term doesn't provably fit the vocabulary budget. `swapCandidateNormalized`/
        /// `swapCandidateSurface` name the least-used currently-active approved term (empty
        /// string if there is no active approved term at all to offer — e.g. the user's own
        /// manual `vocabularyText` alone already fills the budget). Re-invoke with
        /// `confirmSwap: true` to drop that term and approve the new one — NEVER automatic
        /// (requirement 5: "never evict silently").
        case budgetFull(swapCandidateNormalized: String, swapCandidateSurface: String, newTermSurface: String)
        case invalidTerm
        /// `wrongText`/`rightText` didn't reduce to a single anchored word substitution (a whole
        /// rewrite, multiple changes, or no change at all) — nothing recorded. Matches
        /// BRAINSTORM_CORRECTION_LOOP.md's scope: "single misheard words and names," not phrases.
        case noWrongRightPair
    }

    /// Runs the SAME anchored-single-word-substitution diff `VocabularyMiner` uses on
    /// transcript-vs-refined pairs — reused verbatim here, not reimplemented, so "the user
    /// rewrote a whole sentence" produces no vocabulary write from ANY of the three signals, only
    /// a genuine single-word correction does. `surfaceTerm`/`normalizedTerm` come from
    /// `rightText`'s corrected word (already run through `AppSettings.validatedVocabularyTerm` by
    /// the miner's own logic).
    static func candidate(wrongText: String, rightText: String) -> VocabEvidenceCandidate? {
        guard let first = VocabularyMiner.candidates(transcript: wrongText, refined: rightText).first else { return nil }
        return VocabEvidenceCandidate(normalizedTerm: first.normalizedTerm, surfaceTerm: first.surfaceTerm, source: .userSupplied)
    }

    /// Pure decision core (Codex-survivability: factored out of the actor-hopping `record` below
    /// so the dismissed-guard/already-approved/budget-swap logic is directly unit-testable
    /// without a live `VocabStore`/`AppSettings`) — mirrors the `LiveInsertionSession.
    /// finalizeDecision` / `Insertion.classifyPreflightFailure` split of decision from effect.
    nonisolated static func decide(
        existingStatus: VocabDecisionStatus?,
        confirmDismissedOverride: Bool,
        fits: Bool,
        confirmSwap: Bool,
        swapCandidateNormalized: String?,
        swapCandidateSurface: String?,
        surfaceTerm: String
    ) -> Outcome {
        switch existingStatus {
        case .approved:
            return .alreadyApproved
        case .dismissed where !confirmDismissedOverride:
            return .needsDismissalConfirmation(surfaceTerm: surfaceTerm)
        case .dismissed, nil:
            if fits { return .approved }
            guard confirmSwap, swapCandidateNormalized != nil, swapCandidateSurface != nil else {
                return .budgetFull(
                    swapCandidateNormalized: swapCandidateNormalized ?? "",
                    swapCandidateSurface: swapCandidateSurface ?? "",
                    newTermSurface: surfaceTerm
                )
            }
            // confirmSwap == true with a named candidate: the caller already showed the swap
            // offer (built from a PRIOR `.budgetFull` result) and the user agreed — this branch
            // only reports that a swap+approve is now sanctioned; `record` below is what actually
            // performs it. Reported as `.approved` since that's the outcome once `record`
            // executes the swap.
            return .approved
        }
    }

    /// `store`/`settings` are the live dependencies; `confirmSwap`/`confirmDismissedOverride` are
    /// explicit re-invocations after a caller showed the user a `.budgetFull`/
    /// `needsDismissalConfirmation` result and got agreement — never inferred automatically.
    @MainActor
    static func record(
        dictationID: Int64,
        wrongText: String,
        rightText: String,
        store: VocabStore,
        settings: AppSettings = .shared,
        confirmSwap: Bool = false,
        confirmDismissedOverride: Bool = false
    ) async throws -> Outcome {
        guard let candidate = candidate(wrongText: wrongText, rightText: rightText) else { return .noWrongRightPair }
        guard AppSettings.validatedVocabularyTerm(candidate.surfaceTerm) != nil else { return .invalidTerm }

        try await store.recordEvidence(dictationID: dictationID, candidates: [candidate])
        let existing = try await store.decision(normalizedTerm: candidate.normalizedTerm)

        let userTerms = AppSettings.boundedVocabulary(settings.vocabularyText).kept
        let existingApproved = settings.approvedVocabularyCache.map(\.surfaceTerm)
        let fitResult = EffectiveVocabulary.derive(
            userTerms: userTerms, approvedTerms: existingApproved + [candidate.surfaceTerm],
            encode: settings.vocabularyTokenEncoder?()
        )
        let fits = !fitResult.displaced.contains(candidate.surfaceTerm)
        // Least-used approximation (requirement 5): no per-term usage telemetry exists, so the
        // best available proxy for "gone longest without use" is the OLDEST-approved term still
        // in the currently-active set — `activeApproved` preserves `approvedTerms()`'s
        // oldest-decidedAt-first order (see `EffectiveVocabulary.derive`), so its first element
        // is exactly that term. An already-displaced approved term is never offered — evicting it
        // wouldn't free any budget for the new term.
        let swapSurface = fitResult.activeApproved.first
        let swapNormalized = swapSurface.flatMap { surface in
            settings.approvedVocabularyCache.first(where: { $0.surfaceTerm == surface })?.normalizedTerm
        }

        let decision = decide(
            existingStatus: existing?.status,
            confirmDismissedOverride: confirmDismissedOverride,
            fits: fits,
            confirmSwap: confirmSwap,
            swapCandidateNormalized: swapNormalized,
            swapCandidateSurface: swapSurface,
            surfaceTerm: candidate.surfaceTerm
        )

        switch decision {
        case .approved:
            if !fits, confirmSwap, let swapNormalized {
                // Sanctioned swap: drop the offered term, then approve the new one. Two separate
                // writes (never one, so a failure after the drop still leaves the system in a
                // valid state — displaced, not silently corrupted) — matches `dismiss`/`approve`
                // already being independent `VocabStore` actions elsewhere.
                _ = try await store.dismiss(normalizedTerm: swapNormalized)
            }
            _ = try await store.approve(normalizedTerm: candidate.normalizedTerm)
            return .approved
        default:
            return decision
        }
    }
}
