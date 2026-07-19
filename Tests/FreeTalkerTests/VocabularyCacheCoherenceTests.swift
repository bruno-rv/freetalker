import Foundation
import Testing
@testable import FreeTalker

/// PLAN.md PR B, item 2d: the approved-terms cache backing every stop-time snapshot must degrade
/// to "stale, still-correct" on a transient `VocabStore` read failure, never to "empty" — an
/// empty `approvedVocabularyCache` is indistinguishable from "no terms approved" to every
/// consumer (`AppSettings.vocabulary`, `cloudLLMSnapshot`, Settings preview). See Codex round 1
/// finding 3.
@Suite struct VocabularyCacheCoherenceTests {
    private static let existing = [ApprovedVocabularyTerm(normalizedTerm: "joão", surfaceTerm: "João", decidedAt: Date(timeIntervalSince1970: 1))]

    @Test func aFailedReadPreservesTheExistingCache() {
        let resolved = AppCoordinator.resolveApprovedVocabularyCache(current: Self.existing, freshRead: nil)
        #expect(resolved == Self.existing)
    }

    @Test func aSuccessfulReadAlwaysReplacesTheCacheEvenWhenEmpty() {
        // A genuinely empty successful read (every approved term was dismissed) must win over
        // stale `current` data — only a FAILED read (`nil`) falls back.
        let resolved = AppCoordinator.resolveApprovedVocabularyCache(current: Self.existing, freshRead: [])
        #expect(resolved.isEmpty)
    }

    @Test func aSuccessfulReadWithNewTermsReplacesTheCache() {
        let fresh = [ApprovedVocabularyTerm(normalizedTerm: "openai", surfaceTerm: "OpenAI", decidedAt: Date(timeIntervalSince1970: 2))]
        let resolved = AppCoordinator.resolveApprovedVocabularyCache(current: Self.existing, freshRead: fresh)
        #expect(resolved == fresh)
    }

    /// `refreshApprovedVocabularyCache`'s generation guard (mirrors `VocabularySuggestionsController
    /// .generation`): a read that started before a NEWER refresh (so its `requestGeneration` is
    /// stale by the time it completes) must apply nothing, even if it succeeded — a slow read
    /// racing a faster later one must never clobber the cache the later one already applied. See
    /// Codex finding (AppCoordinator.swift:3416).
    @Test func aStaleGenerationReadDoesNotClobberTheCache() {
        let fresh = [ApprovedVocabularyTerm(normalizedTerm: "openai", surfaceTerm: "OpenAI", decidedAt: Date(timeIntervalSince1970: 2))]
        let decision = AppCoordinator.vocabularyCacheApplyDecision(
            requestGeneration: 1, currentGeneration: 2, current: Self.existing, freshRead: fresh
        )
        #expect(decision == nil)
    }

    @Test func aCurrentGenerationReadIsAppliedNormally() {
        let fresh = [ApprovedVocabularyTerm(normalizedTerm: "openai", surfaceTerm: "OpenAI", decidedAt: Date(timeIntervalSince1970: 2))]
        let decision = AppCoordinator.vocabularyCacheApplyDecision(
            requestGeneration: 2, currentGeneration: 2, current: Self.existing, freshRead: fresh
        )
        #expect(decision == fresh)
    }
}
