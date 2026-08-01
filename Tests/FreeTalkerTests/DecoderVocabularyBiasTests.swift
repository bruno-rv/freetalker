import Foundation
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
            Self.vocabulary, refinementCarriesVocabulary: true, biasCostsDecodeTime: true
        ) == [])
    }

    @Test func rawKeepsTheDecoderPromptBecauseNothingElseCarriesTheTerms() {
        #expect(AppCoordinator.decoderBiasVocabulary(
            Self.vocabulary, refinementCarriesVocabulary: false, biasCostsDecodeTime: true
        ) == Self.vocabulary)
    }

    /// Codex adversarial review, 2026-08-01: the withholding is a latency trade, so an engine that
    /// pays no latency for the bias must never be charged for it. `CloudSTTEngine` carries the
    /// terms in a multipart `prompt` field on a request it was already making.
    @Test func anEngineThatPaysNoDecodeTimeAlwaysKeepsTheFullVocabulary() {
        #expect(AppCoordinator.decoderBiasVocabulary(
            Self.vocabulary, refinementCarriesVocabulary: true, biasCostsDecodeTime: false
        ) == Self.vocabulary)
        #expect(CloudSTTEngine().vocabularyBiasCostsDecodeTime == false)
        #expect(WhisperKitEngine().vocabularyBiasCostsDecodeTime == true)
    }

    /// The default is the one that keeps the feature: a `TranscriptionEngine` that never mentions
    /// the cost is never withheld from.
    @Test func anEngineThatDeclaresNothingKeepsTheFullVocabulary() {
        #expect(SilentAboutBiasCostEngine().vocabularyBiasCostsDecodeTime == false)
    }

    // MARK: - The rule as the pipeline actually applies it

    /// A refined Cloud-STT dictation must still put the terms in its request — the withholding is
    /// WhisperKit's decode cost, and Cloud STT has none. Asserts the real multipart body, not just
    /// the predicate (Codex adversarial review, 2026-08-01).
    @Test @MainActor func refinedCloudSTTDictationStillSendsTheVocabularyPrompt() async throws {
        let engine = CloudSTTEngine()
        let vocabulary = AppCoordinator.decoderBiasVocabulary(
            Self.vocabulary,
            refinementCarriesVocabulary: true,
            biasCostsDecodeTime: engine.vocabularyBiasCostsDecodeTime
        )
        let body = engine.multipartBody(
            boundary: "test-boundary", wavData: Data(), model: "whisper-1",
            vocabulary: vocabulary, forcedLanguage: nil
        )

        let bodyText = try #require(String(data: body, encoding: .utf8))
        #expect(bodyText.contains("name=\"prompt\""))
        #expect(bodyText.contains("Qdrant"))
    }

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
    /// Stands in for WhisperKit, the engine the withholding is about.
    nonisolated let vocabularyBiasCostsDecodeTime = true
    private let output: TranscriptionOutput
    private(set) var receivedVocabulary: [String]?

    init(output: TranscriptionOutput) { self.output = output }

    func transcribe(samples: [Float], forcedLanguage: String?, candidateLanguages: [String], vocabulary: [String]) async throws -> TranscriptionOutput {
        receivedVocabulary = vocabulary
        return output
    }
}

/// Declares nothing about bias cost — exercises the protocol default.
private struct SilentAboutBiasCostEngine: TranscriptionEngine {
    let name = "Silent"
    @MainActor var statusText: String { "Ready" }

    func transcribe(samples: [Float], forcedLanguage: String?, candidateLanguages: [String], vocabulary: [String]) async throws -> TranscriptionOutput {
        .init(text: "", language: "en")
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
