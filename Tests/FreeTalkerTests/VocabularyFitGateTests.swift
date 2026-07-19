import Testing
@testable import FreeTalker

@Suite struct VocabularyFitGateTests {
    @Test func emptyListAlwaysFits() {
        #expect(VocabularyFitGate.fits([]))
    }

    @Test func serializedPromptMatchesWhisperKitsOwnLeadingSpaceCommaSeparatedFormat() {
        #expect(VocabularyFitGate.serializedPrompt(["Alpha", "Beta"]) == " Alpha, Beta")
        #expect(VocabularyFitGate.serializedPrompt([]) == "")
    }

    /// PLAN.md PR B, item 4: conservative fallback bound (tokenizer unloaded) — exact serialized
    /// UTF-8 byte count of the Whisper prompt, since every BPE token is at least 1 byte.
    @Test func byteBoundFitsWhenSerializedBytesAreAtOrUnderBudget() {
        let exactFit = String(repeating: "a", count: VocabularyFitGate.tokenBudget - 1) // " " + term == tokenBudget bytes
        #expect(VocabularyFitGate.fits([exactFit]))
        #expect(VocabularyFitGate.serializedPrompt([exactFit]).utf8.count == VocabularyFitGate.tokenBudget)
    }

    @Test func byteBoundNeedsEvictionWhenSerializedBytesExceedBudget() {
        let overBudget = String(repeating: "a", count: VocabularyFitGate.tokenBudget)
        #expect(!VocabularyFitGate.fits([overBudget]))
    }

    /// PLAN.md PR B, item 4: when a tokenizer IS loaded, the exact token count of the same
    /// serialized prompt governs instead of the conservative byte bound — an `encode` that
    /// reports fewer tokens than bytes (the normal BPE case) can admit a list the byte bound alone
    /// would refuse.
    @Test func exactTokenCountFitsWhenByteBoundWouldRefuse() {
        let term = String(repeating: "a", count: VocabularyFitGate.tokenBudget + 100) // over the byte bound
        #expect(!VocabularyFitGate.fits([term], encode: nil))
        // A tokenizer that collapses every 4 bytes into 1 token easily fits under budget.
        #expect(VocabularyFitGate.fits([term], encode: { text in (text.utf8.count + 3) / 4 }))
    }

    @Test func exactTokenCountStillNeedsEvictionWhenOverBudget() {
        let term = String(repeating: "a", count: VocabularyFitGate.tokenBudget * 10)
        #expect(!VocabularyFitGate.fits([term], encode: { text in text.utf8.count })) // 1 token/byte, still over
    }

    /// `serializedByteCount` must stay exactly in lockstep with `serializedPrompt(_:).utf8.count`
    /// — `EffectiveVocabulary.derive` relies on it as a running total instead of re-serializing the
    /// whole growing candidate list on every append. See Codex finding (SettingsView.swift:1288).
    @Test func serializedByteCountMatchesTheRealSerializedPromptsByteLength() {
        #expect(VocabularyFitGate.serializedByteCount([]) == VocabularyFitGate.serializedPrompt([]).utf8.count)
        #expect(VocabularyFitGate.serializedByteCount(["Alpha"]) == VocabularyFitGate.serializedPrompt(["Alpha"]).utf8.count)
        let terms = ["Alpha", "Beta", "João"]
        #expect(VocabularyFitGate.serializedByteCount(terms) == VocabularyFitGate.serializedPrompt(terms).utf8.count)
    }
}
