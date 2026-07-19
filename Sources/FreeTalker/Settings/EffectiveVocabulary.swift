import Foundation

/// The ONE derivation that feeds every consumer of `AppSettings.vocabulary` (PLAN.md PR B, item
/// 2b/5): user-entered terms first (already bounded/deduped by `AppSettings.boundedVocabulary`),
/// then approved terms in `decidedAt` order, filtered through `VocabularyFitGate` so a term that
/// doesn't provably fit is excluded from `active` rather than silently sent to transcription
/// anyway. Pure and synchronous — no SQLite, no actor hop — so it's safe to call from the
/// synchronous stop-time snapshot paths (`cloudLLMSnapshot`, `makeStopRequest`) as well as every
/// other reader, always with whatever `AppSettings` already has in memory (`vocabularyText` +
/// the store actor's eagerly-loaded, republished-on-decision cache — see PLAN.md PR B, item 2d).
///
/// `encode`, when supplied, gives the exact WhisperKit token count of a candidate's serialized
/// prompt (`WhisperKitEngine.currentVocabularyEncoder()` — nil until a model/tokenizer is
/// actually loaded); `nil` falls back to the conservative byte-count bound
/// (`VocabularyFitGate.fits(_:encode:)`'s own default). Every caller of `derive` — the approval
/// gate (`VocabularySuggestionsController`) and every read (`AppSettings.effectiveVocabulary`) —
/// passes the SAME live encoder, so "approved ⇒ active" stays true across reads for as long as
/// the loaded-model state doesn't change; a model swap (or a tokenizer finishing its load between
/// approval and a later read) is exactly the kind of state change PLAN.md PR B, item 2e's
/// continuous revalidation already tolerates — a term that no longer fits becomes `displaced`,
/// never silently sent to transcription anyway.
enum EffectiveVocabulary {
    struct Result: Equatable, Sendable {
        /// What every consumer (WhisperKit biasing, Cloud STT, Cloud LLM snapshot, Apple FM,
        /// Settings preview) should use.
        let active: [String]
        /// The subset of `active` that came from `approvedTerms` (validated/dropped exactly like
        /// `active` itself), in the original (pre-validation) spelling passed in — lets a caller
        /// like Settings match back against `approvedVocabularyCache` entries to render the true
        /// active/displaced/dropped partition instead of reconstructing "cache minus displaced"
        /// (which wrongly counted a term dropped by validation-failure or case-dedupe as active).
        /// See PLAN.md PR B, item 2e; Codex finding (SettingsView.swift:1297).
        let activeApproved: [String]
        /// Approved terms currently excluded because they don't fit alongside `active` — never
        /// silently treated as active; Settings surfaces these as needing an explicit eviction
        /// decision (dismiss) or a trimmed `vocabularyText`. See PLAN.md PR B, item 2e.
        let displaced: [String]
    }

    /// `approvedTerms` must already be in the order they should be considered for inclusion
    /// (oldest `decidedAt` first — see `VocabStore.approvedTerms()`). Case-insensitive dedupe
    /// against `userTerms` (first spelling — the user's own — wins) so a term the user has also
    /// typed manually is never duplicated in the prompt. Each approved term is re-validated
    /// through `AppSettings.validatedVocabularyTerm` — the SAME validator `boundedVocabulary`
    /// applies to `userTerms` — before it's ever considered for `active`; an approved term that
    /// fails it (defense in depth — mining/approval should never produce one) is silently dropped,
    /// same as an invalid manually-typed line.
    static func derive(userTerms: [String], approvedTerms: [String], encode: ((String) -> Int)? = nil) -> Result {
        var seenLowercased = Set(userTerms.map { $0.lowercased() })
        var active = userTerms
        var activeApproved: [String] = []
        var displaced: [String] = []
        // Running byte total for `active`'s serialized prompt (see `VocabularyFitGate.
        // serializedByteCount`) — computed once up front, then updated by a fixed per-term delta
        // on every accepted append, rather than re-serializing the whole (growing) `active` list
        // from scratch on every candidate check. Only used when `encode` is nil; the tokenizer
        // path can't be made incremental without breaking the "exact token count of the real
        // serialized prompt" guarantee (BPE merges aren't additive across a join boundary), so it
        // still serializes+encodes the (mutated-then-possibly-rolled-back) candidate directly.
        var byteTotal = VocabularyFitGate.serializedByteCount(active)
        for term in approvedTerms {
            guard let validated = AppSettings.validatedVocabularyTerm(term) else { continue }
            guard seenLowercased.insert(validated.lowercased()).inserted else { continue }
            let delta = validated.utf8.count + (active.isEmpty ? 0 : 2)
            let candidateByteTotal = byteTotal + delta
            let fits: Bool
            if let encode {
                active.append(validated)
                fits = encode(VocabularyFitGate.serializedPrompt(active)) <= VocabularyFitGate.tokenBudget
                if !fits { active.removeLast() }
            } else {
                fits = candidateByteTotal <= VocabularyFitGate.tokenBudget
                if fits { active.append(validated) }
            }
            if fits {
                byteTotal = candidateByteTotal
                activeApproved.append(term)
            } else {
                displaced.append(term)
            }
        }
        return Result(active: active, activeApproved: activeApproved, displaced: displaced)
    }
}
