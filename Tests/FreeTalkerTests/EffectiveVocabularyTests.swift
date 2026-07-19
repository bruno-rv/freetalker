import Foundation
import Testing
@testable import FreeTalker

@Suite("Effective vocabulary derivation")
struct EffectiveVocabularyTests {
    @Test func userTermsComeFirstThenApprovedTermsInOrder() {
        let result = EffectiveVocabulary.derive(userTerms: ["Alpha"], approvedTerms: ["Beta", "Gamma"])
        #expect(result.active == ["Alpha", "Beta", "Gamma"])
        #expect(result.displaced.isEmpty)
    }

    @Test func approvedTermDuplicatingAUserTermCaseInsensitivelyIsDropped() {
        let result = EffectiveVocabulary.derive(userTerms: ["OpenAI"], approvedTerms: ["openai", "Gamma"])
        #expect(result.active == ["OpenAI", "Gamma"])
    }

    /// SettingsView must render the TRUE active/displaced partition, not "cache minus displaced"
    /// (which wrongly counted a term dropped by case-insensitive dedupe — neither active nor
    /// displaced — as active). See Codex finding (SettingsView.swift:1297).
    @Test func caseInsensitiveDuplicateOfAUserTermIsNeitherActiveApprovedNorDisplaced() {
        let result = EffectiveVocabulary.derive(userTerms: ["OpenAI"], approvedTerms: ["openai", "Gamma"])
        #expect(result.active == ["OpenAI", "Gamma"])
        #expect(result.activeApproved == ["Gamma"])
        #expect(result.displaced.isEmpty)
    }

    /// PLAN.md PR B, item 4's "tokenizer loaded → exact token count" path — previously `derive`
    /// never accepted an `encode` closure at all, so every consumer (including the approval-time
    /// fit check) was always evaluated against the conservative byte bound: terms whose combined
    /// byte-serialized form exceeds `tokenBudget` but would tokenize well under it stayed
    /// permanently displaced even with a model loaded. (A SINGLE over-budget term can't be used
    /// here: `AppSettings.maxVocabularyTermLength`'s 50-byte-per-term validator would drop it
    /// before it ever reaches the fit gate — same 15-terms-combined shape as
    /// `approvedTermsBeyondTheFitBudgetAreDisplacedNotActive` above.) See Codex finding
    /// (EffectiveVocabulary.swift:49).
    @Test func termsFailingTheByteBoundButFittingByExactTokenCountAreActive() {
        let terms = (0..<15).map { "filler-term-number-\(String(format: "%02d", $0))" }
        let byteBoundOnly = EffectiveVocabulary.derive(userTerms: [], approvedTerms: terms)
        #expect(!byteBoundOnly.displaced.isEmpty)

        // A tokenizer that collapses every 4 bytes into 1 token easily fits the whole list under
        // budget (~344 serialized bytes / 4 ≈ 86 tokens, well under `tokenBudget`).
        let withTokenizer = EffectiveVocabulary.derive(
            userTerms: [], approvedTerms: terms, encode: { text in (text.utf8.count + 3) / 4 }
        )
        #expect(withTokenizer.active == terms)
        #expect(withTokenizer.activeApproved == terms)
        #expect(withTokenizer.displaced.isEmpty)
    }

    @Test func approvedTermsBeyondTheFitBudgetAreDisplacedNotActive() throws {
        // Each term is individually valid (21 bytes, well under the 50-byte per-term cap), but
        // enough of them cumulatively exceed VocabularyFitGate.tokenBudget that later terms
        // (in decidedAt order) are displaced while earlier ones stay active — never the reverse
        // (PLAN.md PR B, item 2e: an earlier approval keeps priority over a later one).
        let terms = (0..<15).map { "filler-term-number-\(String(format: "%02d", $0))" }
        let result = EffectiveVocabulary.derive(userTerms: [], approvedTerms: terms)
        #expect(!result.active.isEmpty)
        #expect(!result.displaced.isEmpty)
        #expect(result.active + result.displaced == terms)
        #expect(VocabularyFitGate.fits(result.active))
        let firstDisplaced = try #require(result.displaced.first)
        #expect(!VocabularyFitGate.fits(result.active + [firstDisplaced]))
    }

    /// PLAN.md PR B, item 2b: the shared 50-byte/control-character validator applies identically
    /// to manual and approved terms — an approved term that fails it is dropped exactly like an
    /// invalid manually-typed line in `AppSettings.boundedVocabulary`.
    @Test func approvedTermFailingTheSharedValidatorIsDropped() {
        let tooLong = String(repeating: "a", count: AppSettings.maxVocabularyTermLength + 1)
        let controlCharacter = "bad\u{0007}term"
        let result = EffectiveVocabulary.derive(userTerms: [], approvedTerms: [tooLong, controlCharacter, "João"])
        #expect(result.active == ["João"])
        #expect(result.displaced.isEmpty)
    }

    /// PLAN.md PR B, item 2b: ALL consumers of `AppSettings.vocabulary` — WhisperKit biasing,
    /// Cloud STT, `cloudLLMSnapshot` (Cloud LLM + Apple FM both read `snapshot.vocabulary`/
    /// `AppSettings.shared.vocabulary`), and the Settings preview — go through this ONE property,
    /// so proving `vocabulary`/`cloudLLMSnapshot.vocabulary` include an approved term proves every
    /// consumer does.
    @MainActor
    @Test func approvedVocabularyCacheFlowsIntoVocabularyAndCloudLLMSnapshot() throws {
        let suite = "EffectiveVocabularyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.vocabularyText = "OpenAI"

        settings.applyApprovedVocabularyCache([
            ApprovedVocabularyTerm(normalizedTerm: "joão", surfaceTerm: "João", decidedAt: Date())
        ])

        #expect(settings.vocabulary == ["OpenAI", "João"])
        #expect(settings.cloudLLMSnapshot.vocabulary == ["OpenAI", "João"])
        #expect(settings.displacedApprovedVocabularyTerms.isEmpty)
    }

    /// Manual `vocabularyText` edits revalidate the effective vocabulary on every read (PLAN.md PR
    /// B, item 2e) — no separate "revalidation" step needed since `vocabulary` is a pure computed
    /// property over current `vocabularyText` + the current approved cache.
    @MainActor
    @Test func manualEditCanDisplaceAPreviouslyFittingApprovedTerm() throws {
        let suite = "EffectiveVocabularyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let approved = ApprovedVocabularyTerm(normalizedTerm: "term", surfaceTerm: "term", decidedAt: Date())
        settings.applyApprovedVocabularyCache([approved])
        #expect(settings.vocabulary.contains("term"))

        // 15 distinct, individually-valid (21-byte) terms — well under `boundedVocabulary`'s own
        // 600-byte/100-term UI cap (so every line is kept), but their combined serialized prompt
        // exceeds `VocabularyFitGate.tokenBudget`, which is what should displace "term".
        settings.vocabularyText = (0..<15).map { "filler-term-number-\(String(format: "%02d", $0))" }.joined(separator: "\n")

        #expect(!settings.vocabulary.contains("term"))
        #expect(settings.displacedApprovedVocabularyTerms.contains("term"))
    }
}
