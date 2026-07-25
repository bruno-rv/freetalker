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

    /// A deliberate, explicit user correction (Codex finding 7) — NOT `VocabularyMiner.
    /// candidates`. The miner's anchor-position/minimum-length/edit-distance heuristics exist to
    /// filter its own GUESSES out of unattributed transcript-vs-refined diffs (is this really a
    /// spelling fix, or an unrelated rewrite?); they have no business filtering a correction the
    /// user just explicitly made through the panel, a spoken correction, or a confirmed observed
    /// edit. A correction at the first/last word, shorter than `VocabularyMiner.minTermLength`, or
    /// with an edit distance above `VocabularyMiner.maxEditDistance` was previously repairing the
    /// live document and then silently discarded as `.noWrongRightPair` — this branch's whole
    /// premise (a correction is fed directly, past the miner's queue) barely worked. Still
    /// requires exactly ONE changed token — a whole-sentence rewrite still yields no candidate,
    /// matching BRAINSTORM_CORRECTION_LOOP.md's "single misheard words and names" scope — via the
    /// SAME LCS hunk-detection `VocabularyMiner.replacementHunks` uses (reused, not reimplemented;
    /// `VocabularyMiner` itself is unchanged). `surfaceTerm`/`normalizedTerm` still go through
    /// `AppSettings.validatedVocabularyTerm` (`record` below), same validation every vocabulary
    /// write gets regardless of source.
    static func candidate(wrongText: String, rightText: String) -> VocabEvidenceCandidate? {
        guard let substitution = correctionSubstitution(wrongText: wrongText, rightText: rightText) else { return nil }
        guard let canonicalSurface = AppSettings.validatedVocabularyTerm(substitution.newWord) else { return nil }
        return VocabEvidenceCandidate(normalizedTerm: canonicalSurface.lowercased(), surfaceTerm: canonicalSurface, source: .userSupplied)
    }

    /// The single-token substitution `candidate(wrongText:rightText:)` requires: exactly one
    /// changed token between the two texts, at ANY position (including the very first/last word),
    /// of ANY length, at ANY edit distance — none of `VocabularyMiner`'s guess-filtering
    /// heuristics apply here (see `candidate`'s doc comment). Reuses `VocabularyMiner.tokenize`/
    /// `replacementHunks` (unchanged) rather than a parallel diff implementation.
    static func correctionSubstitution(wrongText: String, rightText: String) -> (oldWord: String, newWord: String)? {
        let oldTokens = VocabularyMiner.tokenize(wrongText)
        let newTokens = VocabularyMiner.tokenize(rightText)
        guard !oldTokens.isEmpty, !newTokens.isEmpty else { return nil }
        let hunks = VocabularyMiner.replacementHunks(old: oldTokens, new: newTokens)
        guard hunks.count == 1, let hunk = hunks.first,
              hunk.oldTokens.count == 1, hunk.newTokens.count == 1,
              hunk.oldTokens[0] != hunk.newTokens[0]
        else { return nil }
        return (hunk.oldTokens[0], hunk.newTokens[0])
    }

    /// Pure decision core (Codex-survivability: factored out of the actor-hopping `record` below
    /// so the dismissed-guard/already-approved/budget-swap logic is directly unit-testable
    /// without a live `VocabStore`/`AppSettings`) — mirrors the `LiveInsertionSession.
    /// finalizeDecision` / `Insertion.classifyPreflightFailure` split of decision from effect.
    ///
    /// `expectedSwapNormalizedTerm` (Codex Round 2 finding 4), when non-nil, is the swap candidate
    /// a caller's FROZEN offer named — the panel's Swap button re-confirms THIS term specifically,
    /// never whatever `swapCandidateNormalized` recomputes as "currently oldest." If the caller's
    /// remembered candidate no longer matches what's freshly computed here (e.g. the offered term
    /// was dismissed via Settings between the offer and the click), the swap+approve is refused —
    /// this falls through to a NEW `.budgetFull` naming the CURRENT candidate, never silently
    /// swapping a different term than the one consent named. `nil` (every pre-fix call site,
    /// including a first-pass `confirmSwap: false` call) skips this check entirely.
    nonisolated static func decide(
        existingStatus: VocabDecisionStatus?,
        confirmDismissedOverride: Bool,
        fits: Bool,
        confirmSwap: Bool,
        swapCandidateNormalized: String?,
        swapCandidateSurface: String?,
        surfaceTerm: String,
        expectedSwapNormalizedTerm: String? = nil
    ) -> Outcome {
        switch existingStatus {
        case .approved:
            return .alreadyApproved
        case .dismissed where !confirmDismissedOverride:
            return .needsDismissalConfirmation(surfaceTerm: surfaceTerm)
        case .dismissed, nil:
            if fits { return .approved }
            let swapStillApplicable = expectedSwapNormalizedTerm == nil || expectedSwapNormalizedTerm == swapCandidateNormalized
            guard confirmSwap, swapCandidateNormalized != nil, swapCandidateSurface != nil, swapStillApplicable else {
                return .budgetFull(
                    swapCandidateNormalized: swapCandidateNormalized ?? "",
                    swapCandidateSurface: swapCandidateSurface ?? "",
                    newTermSurface: surfaceTerm
                )
            }
            // confirmSwap == true with a named candidate that's still the exact one consent named
            // (or no consent was frozen at all): the caller already showed the swap offer (built
            // from a PRIOR `.budgetFull` result) and the user agreed — this branch only reports
            // that a swap+approve is now sanctioned; `record` below is what actually performs it.
            // Reported as `.approved` since that's the outcome once `record` executes the swap.
            return .approved
        }
    }

    /// Minimal FIFO async mutex (Codex finding 10) — `acquire()` suspends until it's this
    /// caller's turn; `release()` is a plain synchronous call (usable from `defer`) that wakes the
    /// next waiter, if any. `@MainActor`-isolated since its only caller (`record` below) already
    /// is — no separate actor hop needed. `record`'s own `@MainActor` isolation alone does NOT
    /// serialize concurrent calls: the race is entirely across `await` suspension points (the
    /// `VocabStore` reads/writes below), where the MainActor freely interleaves a second `record`
    /// call.
    @MainActor
    private final class RecordLock {
        private var isLocked = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !isLocked {
                isLocked = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            guard !waiters.isEmpty else {
                isLocked = false
                return
            }
            waiters.removeFirst().resume()
        }
    }

    private static let recordLock = RecordLock()

    /// `store`/`settings` are the live dependencies; `confirmSwap`/`confirmDismissedOverride` are
    /// explicit re-invocations after a caller showed the user a `.budgetFull`/
    /// `needsDismissalConfirmation` result and got agreement — never inferred automatically.
    ///
    /// Codex finding 10: the entire fit-check → write → cache-refresh sequence is serialized
    /// process-wide via `recordLock` — without it, two corrections landing concurrently (e.g.
    /// signal B and signal C on different windows) each `await` past the fit-check before either
    /// has committed its own decision, so both read the SAME stale `settings.
    /// approvedVocabularyCache`, both conclude they fit, and both approve — one is later silently
    /// displaced by the other with neither having received the required budget-full offer. Every
    /// call therefore evaluates its fit-check against the PRECEDING call's fully-committed
    /// decision, never a stale snapshot from before it.
    @MainActor
    static func record(
        dictationID: Int64,
        wrongText: String,
        rightText: String,
        store: VocabStore,
        settings: AppSettings = .shared,
        confirmSwap: Bool = false,
        confirmDismissedOverride: Bool = false,
        expectedSwapNormalizedTerm: String? = nil
    ) async throws -> Outcome {
        await recordLock.acquire()
        do {
            let outcome = try await recordLocked(
                dictationID: dictationID, wrongText: wrongText, rightText: rightText, store: store,
                settings: settings, confirmSwap: confirmSwap, confirmDismissedOverride: confirmDismissedOverride,
                expectedSwapNormalizedTerm: expectedSwapNormalizedTerm
            )
            recordLock.release()
            return outcome
        } catch {
            recordLock.release()
            throw error
        }
    }

    @MainActor
    private static func recordLocked(
        dictationID: Int64,
        wrongText: String,
        rightText: String,
        store: VocabStore,
        settings: AppSettings,
        confirmSwap: Bool,
        confirmDismissedOverride: Bool,
        expectedSwapNormalizedTerm: String? = nil
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
            surfaceTerm: candidate.surfaceTerm,
            expectedSwapNormalizedTerm: expectedSwapNormalizedTerm
        )

        switch decision {
        case .approved:
            if !fits, confirmSwap, let swapNormalized {
                // Codex finding 11: verify evidence, dismiss the offered term, and approve the
                // confirmed one in ONE `VocabStore` transaction — two separate writes here
                // previously meant a failure between them left the offered term dismissed with
                // the confirmed one never approved, losing both.
                _ = try await store.swapApprove(
                    dismissNormalizedTerm: swapNormalized, approveNormalizedTerm: candidate.normalizedTerm,
                    // Codex finding 8: the candidate's own validated surface, not a mined-evidence
                    // tie-break that could resurface a higher-frequency mined misspelling.
                    approveSurfaceTerm: candidate.surfaceTerm
                )
            } else {
                _ = try await store.approve(normalizedTerm: candidate.normalizedTerm, surfaceTerm: candidate.surfaceTerm)
            }
            // Codex finding 10: refreshed INSIDE the serialized section — not left to the
            // caller's own async refresh afterward — so the NEXT waiting `record()` call sees
            // this decision's effect on the fit-check budget, not a stale pre-decision snapshot.
            settings.applyApprovedVocabularyCache(try await store.approvedTerms())
            return .approved
        default:
            return decision
        }
    }
}
