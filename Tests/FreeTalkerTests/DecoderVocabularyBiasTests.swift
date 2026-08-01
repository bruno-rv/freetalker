import Testing
@testable import FreeTalker

/// Biasing WhisperKit with `promptTokens` costs one full decoder inference per prompt token per
/// 30 s window (see `AppCoordinator.decoderBiasVocabulary`), so which paths pay for it is a
/// latency decision, not a detail. These pin the rule: the decoder prompt is spent only where no
/// LLM pass will carry the same terms.
@Suite struct DecoderVocabularyBiasTests {
    private static let template = Template(id: "clean-dictation", name: "Clean Dictation", prompt: "Clean this up.")
    private static let vocabulary = ["Qdrant", "Data Vault Builder"]

    // MARK: - The rule itself

    @Test func refinementCarryingTheVocabularyWithholdsTheDecoderPrompt() {
        #expect(AppCoordinator.decoderBiasVocabulary(
            Self.vocabulary, refinementCarriesVocabulary: true
        ) == [])
    }

    @Test func rawKeepsTheDecoderPromptBecauseNothingElseCarriesTheTerms() {
        #expect(AppCoordinator.decoderBiasVocabulary(
            Self.vocabulary, refinementCarriesVocabulary: false
        ) == Self.vocabulary)
    }

    // MARK: - The rule as the pipeline actually applies it

    /// The full snapshot must still reach the post-processor — the terms are not dropped, they
    /// move to the pass that can apply them for free.
    @Test @MainActor func refinedDictationBiasesTheProcessorButNotTheDecoder() async throws {
        let engine = VocabularyRecordingTranscriptionSpy(output: .init(text: "raw transcript", language: "en"))
        let processor = VocabularyRecordingProcessorSpy(result: "refined output")
        let context = RecordingProcessingContext(
            destination: .external, spokenLanguage: "en", outputLanguage: .sameAsSpoken,
            template: Self.template, cloudSnapshot: nil, voiceCommandPolicy: .disabled,
            candidateLanguages: ["en"], vocabularySnapshot: Self.vocabulary
        )

        _ = try await AppCoordinator.shared.processDictation(
            samples: [0.4], engine: engine, engineName: "Spy", context: context,
            skipPostProcessing: false, processor: processor,
            insert: { _, _ in true }, record: { _ in }
        )

        #expect(await engine.receivedVocabulary == [])
        #expect(await processor.receivedVocabulary == Self.vocabulary)
    }

    /// Raw has no LLM pass at all, so withholding the prompt here would silently delete the
    /// feature rather than relocate it.
    @Test @MainActor func rawDictationStillBiasesTheDecoder() async throws {
        let engine = VocabularyRecordingTranscriptionSpy(output: .init(text: "raw transcript", language: "en"))
        let context = RecordingProcessingContext(
            destination: .external, spokenLanguage: "en", outputLanguage: .sameAsSpoken,
            template: Self.template, cloudSnapshot: nil, voiceCommandPolicy: .disabled,
            candidateLanguages: ["en"], vocabularySnapshot: Self.vocabulary
        )

        _ = try await AppCoordinator.shared.processDictation(
            samples: [0.4], engine: engine, engineName: "Spy", context: context,
            skipPostProcessing: true, insert: { _, _ in true }, record: { _ in }
        )

        #expect(await engine.receivedVocabulary == Self.vocabulary)
    }

    // MARK: - Detection the decode does not need to pay for

    @Test func aForcedLanguageNeedsNoDetection() {
        #expect(WhisperKitEngine.predeterminedLanguage(forced: "pt", candidates: ["en", "pt"]) == "pt")
    }

    /// Equivalence, not a heuristic: `constrainedLanguage` is an argmax restricted to
    /// `candidates`, so a one-element set resolves to that element for every distribution the
    /// detection pass could have returned.
    @Test func aSingleCandidateResolvesWithoutDetection() {
        #expect(WhisperKitEngine.predeterminedLanguage(forced: nil, candidates: ["pt"]) == "pt")
        #expect(WhisperKitEngine.constrainedLanguage(
            langProbs: ["en": 0.99, "pt": 0.01], candidates: ["pt"]
        ) == "pt")
    }

    @Test func severalCandidatesStillRequireDetection() {
        #expect(WhisperKitEngine.predeterminedLanguage(forced: nil, candidates: ["en", "pt"]) == nil)
        #expect(WhisperKitEngine.predeterminedLanguage(forced: nil, candidates: []) == nil)
    }
}

private actor VocabularyRecordingTranscriptionSpy: TranscriptionEngine {
    nonisolated let name = "Spy"
    nonisolated var statusText: String { "Ready" }
    private let output: TranscriptionOutput
    private(set) var receivedVocabulary: [String]?

    init(output: TranscriptionOutput) { self.output = output }

    func transcribe(samples: [Float], forcedLanguage: String?, candidateLanguages: [String], vocabulary: [String]) async throws -> TranscriptionOutput {
        receivedVocabulary = vocabulary
        return output
    }
}

private actor VocabularyRecordingProcessorSpy: PostProcessor {
    private let result: String
    private(set) var receivedVocabulary: [String]?

    init(result: String) { self.result = result }

    func process(_ request: PostProcessingRequest) async throws -> String {
        receivedVocabulary = request.vocabulary
        return result
    }
}
