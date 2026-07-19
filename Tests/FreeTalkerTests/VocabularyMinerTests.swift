import Testing
@testable import FreeTalker

@Suite struct VocabularyMinerTests {
    @Test func casingFixProducesOneCandidate() {
        // "joao" is anchored on both sides by unchanged tokens ("hi" before, "how" after) so the
        // diff isolates it as its own 1-for-1 hunk rather than merging with an adjacent change.
        let candidates = VocabularyMiner.candidates(transcript: "hi joao how are you", refined: "hi João how are you")
        #expect(candidates == [VocabEvidenceCandidate(normalizedTerm: "joão", surfaceTerm: "João")])
    }

    @Test func ptAccentFixProducesOneCandidate() {
        let candidates = VocabularyMiner.candidates(transcript: "acho que voce sabe", refined: "acho que você sabe")
        #expect(candidates == [VocabEvidenceCandidate(normalizedTerm: "você", surfaceTerm: "você")])
    }

    @Test func wholeTranscriptSingleWordReplacementProducesNoCandidateBecauseNothingAnchorsIt() {
        // The entire transcript is one token replaced by one token — no surrounding matched
        // context on either side, so this is not an "anchored local substitution" per PLAN.md PR
        // B item 1, even though it satisfies length/edit-distance checks. See Codex round 1 minor
        // finding (`VocabularyMiner.swift:51`).
        let candidates = VocabularyMiner.candidates(transcript: "joao", refined: "João")
        #expect(candidates.isEmpty)
    }

    @Test func replacementAtTheStartOfTheTranscriptProducesNoCandidateBecauseItHasNoLeftAnchor() {
        let candidates = VocabularyMiner.candidates(transcript: "joao how are you", refined: "João how are you")
        #expect(candidates.isEmpty)
    }

    @Test func replacementAtTheEndOfTheTranscriptProducesNoCandidateBecauseItHasNoRightAnchor() {
        let candidates = VocabularyMiner.candidates(transcript: "hi how are joao", refined: "hi how are João")
        #expect(candidates.isEmpty)
    }

    @Test func wholeSentenceRewriteProducesNoCandidate() {
        let candidates = VocabularyMiner.candidates(
            transcript: "I think we should meet tomorrow",
            refined: "Let's schedule a meeting for next week"
        )
        #expect(candidates.isEmpty)
    }

    @Test func identicalTranscriptAndRefinedProduceNoCandidate() {
        #expect(VocabularyMiner.candidates(transcript: "hello world", refined: "hello world").isEmpty)
    }

    @Test func shortTermBelowMinimumLengthIsNotACandidate() {
        // "teh" -> "the": edit distance 2, but under minTermLength (4).
        let candidates = VocabularyMiner.candidates(transcript: "teh cat sat", refined: "the cat sat")
        #expect(candidates.isEmpty)
    }

    @Test func editDistanceAboveThresholdIsNotACandidate() {
        let candidates = VocabularyMiner.candidates(transcript: "please call marcus today", refined: "please call alexander today")
        #expect(candidates.isEmpty)
    }

    /// PLAN.md PR B, item 2b: mined terms go through the SAME shared validator manual/approved
    /// terms use — a refined replacement containing a control character must never become
    /// evidence, even though it's otherwise a perfectly anchored 1-for-1 casing-style hunk. See
    /// Codex round 1 finding 5.
    @Test func replacementContainingAControlCharacterProducesNoCandidate() {
        let candidates = VocabularyMiner.candidates(transcript: "hi joao how are you", refined: "hi jo\u{0007}ao how are you")
        #expect(candidates.isEmpty)
    }

    /// Same validator, the other rejection path: a replacement whose NFC-normalized UTF-8 byte
    /// length exceeds `AppSettings.maxVocabularyTermLength` (50) never becomes evidence.
    @Test func replacementExceedingTheSharedByteLengthCapProducesNoCandidate() {
        let overlong = String(repeating: "a", count: AppSettings.maxVocabularyTermLength + 1)
        let candidates = VocabularyMiner.candidates(transcript: "hi joaoooo how are you", refined: "hi \(overlong) how are you")
        #expect(candidates.isEmpty)
    }

    /// `normalizedTerm` is derived from the CANONICAL (NFC-precomposed) surface, not the raw
    /// token — a decomposed "João" (combining tilde, U+006E U+0303) mines to the same
    /// precomposed evidence as the composed form, so two Unicode representations of one spelling
    /// can never split into two separate normalized terms.
    @Test func replacementNormalizesToItsPrecomposedCanonicalForm() {
        let decomposed = "Joa\u{0303}o" // "Joa" + combining tilde + "o" — NOT precomposed
        // Swift `String`/`Character` equality is already canonical-equivalence-aware (grapheme
        // clusters), so the scalar-level representations must be compared directly to actually
        // exercise the un-normalized encoding this test cares about.
        #expect(Array(decomposed.unicodeScalars) != Array(decomposed.precomposedStringWithCanonicalMapping.unicodeScalars))
        let candidates = VocabularyMiner.candidates(transcript: "hi joao how are you", refined: "hi \(decomposed) how are you")
        #expect(candidates.count == 1)
        let candidate = candidates.first
        #expect(candidate.map { Array($0.surfaceTerm.unicodeScalars) } == Array("João".unicodeScalars))
        #expect(candidate?.normalizedTerm == "joão")
    }

    @Test func candidatesAreCappedPerDictation() {
        // Each substitution is anchored by a distinct "keepN" token on either side so the diff
        // produces 20 separate 1-for-1 hunks rather than one giant unanchored block.
        // "terma\(n)" -> "termb\(n)" is a single-character substitution (edit distance 1).
        let oldWords = (0..<20).flatMap { ["keep\($0)", "terma\($0)"] } + ["keep20"]
        let newWords = (0..<20).flatMap { ["keep\($0)", "termb\($0)"] } + ["keep20"]
        let candidates = VocabularyMiner.candidates(
            transcript: oldWords.joined(separator: " "),
            refined: newWords.joined(separator: " ")
        )
        #expect(candidates.count == VocabularyMiner.maxCandidatesPerDictation)
    }

    // MARK: - levenshteinDistance

    /// Both empty-argument cases directly, not just via `candidates` (which never reaches an empty
    /// word since `minTermLength` already guards it) — before the symmetric guard, `distance("abc",
    /// "")` crashed (`ClosedRange` traps constructing `1...0`). See Codex finding
    /// (VocabularyMiner.swift:160).
    @Test func levenshteinDistanceOfTwoEmptyStringsIsZero() {
        #expect(VocabularyMiner.levenshteinDistance("", "") == 0)
    }

    @Test func levenshteinDistanceAgainstAnEmptyStringIsTheOtherStringsLength() {
        #expect(VocabularyMiner.levenshteinDistance("abc", "") == 3)
        #expect(VocabularyMiner.levenshteinDistance("", "abc") == 3)
    }

    // MARK: - Eligibility

    @Test func sameLanguageRefinedRowIsEligible() {
        #expect(VocabularyMiner.isEligible(requestedOutputLanguage: .sameAsSpoken, templateName: "Clean", voiceCommandsActive: false))
    }

    @Test func translationRowIsIneligible() {
        #expect(!VocabularyMiner.isEligible(requestedOutputLanguage: .spanish, templateName: "Clean", voiceCommandsActive: false))
    }

    @Test func rawTranscriptRowIsIneligible() {
        #expect(!VocabularyMiner.isEligible(requestedOutputLanguage: .sameAsSpoken, templateName: TemplateStore.rawTranscriptTemplateName, voiceCommandsActive: false))
    }

    @Test func voiceCommandsActiveTrueRowIsIneligible() {
        #expect(!VocabularyMiner.isEligible(requestedOutputLanguage: .sameAsSpoken, templateName: "Clean", voiceCommandsActive: true))
    }

    /// PR A's tri-state contract: NULL means "legacy/unknown, possibly command-processed" — never
    /// treated as safe to mine. See PLAN.md PR B, item 1 and `Dictation.voiceCommandsActive`'s doc
    /// comment.
    @Test func voiceCommandsActiveNilRowIsIneligible() {
        #expect(!VocabularyMiner.isEligible(requestedOutputLanguage: .sameAsSpoken, templateName: "Clean", voiceCommandsActive: nil))
    }
}
