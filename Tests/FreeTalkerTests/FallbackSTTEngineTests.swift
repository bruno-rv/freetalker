import Foundation
import Testing
@testable import FreeTalker

/// A cloud stop that throws used to end as a failed job the user had to find under Recoveries and
/// retry by hand — where it succeeded instantly, because retry has always run locally. These pin
/// the live path to the same rule, and pin what it reports afterwards: a substitution nobody can
/// see is how a dead endpoint hides for weeks.
@Suite struct FallbackSTTEngineTests {
    private static let samples = [Float](repeating: 0.1, count: 16_000)

    private func transcribe(_ engine: FallbackSTTEngine, vocabulary: [String] = []) async throws -> TranscriptionOutput {
        try await engine.transcribe(
            samples: Self.samples, forcedLanguage: nil, candidateLanguages: [], vocabulary: vocabulary
        )
    }

    @Test func cloudSuccessNeverRunsTheLocalEngineAndClaimsNoSubstitution() async throws {
        let local = STTSpy(result: .success("local"))
        let engine = FallbackSTTEngine(
            primary: STTSpy(result: .success("cloud"), name: "Cloud STT"),
            fallback: local, skipsPrimary: false
        )

        let output = try await transcribe(engine)

        #expect(output.text == "cloud")
        // `nil` is what stops every ordinary cloud dictation from flashing a substitution notice.
        #expect(output.producedBy == nil)
        #expect(await local.callCount == 0)
    }

    @Test func aFailingCloudIsAnsweredLocallyAndSaysWhichEngineRan() async throws {
        let engine = FallbackSTTEngine(
            primary: STTSpy(result: .failure(URLError(.timedOut)), name: "Cloud STT"),
            fallback: STTSpy(result: .success("local"), name: "WhisperKit"),
            skipsPrimary: false
        )

        let output = try await transcribe(engine)

        #expect(output.text == "local")
        #expect(output.producedBy == "WhisperKit")
    }

    /// The Settings warning knows this base URL serves no `/audio/transcriptions`. Spending the
    /// whole timeout rediscovering that is the wait this removes.
    @Test func aBaseURLThatServesNoTranscriptionEndpointSkipsTheCloudEntirely() async throws {
        let cloud = STTSpy(result: .success("cloud"), name: "Cloud STT")
        let engine = FallbackSTTEngine(
            primary: cloud, fallback: STTSpy(result: .success("local"), name: "WhisperKit"),
            skipsPrimary: true
        )

        let output = try await transcribe(engine)

        #expect(output.text == "local")
        #expect(output.producedBy == "WhisperKit")
        #expect(await cloud.callCount == 0)
    }

    @Test(arguments: [
        "https://ollama.com/v1", "https://api.ollama.com/v1", "http://localhost:11434/v1"
    ])
    func ollamaShapedBaseURLsAreTheOnesSkipped(_ baseURL: String) {
        #expect(FallbackSTTEngine.skipPrimary(baseURL: baseURL))
    }

    @Test func anOpenAICompatibleBaseURLIsStillAttempted() {
        #expect(FallbackSTTEngine.skipPrimary(baseURL: "https://api.openai.com/v1") == false)
    }

    /// A cloud-only user has no local model downloaded — the exact person this feature is for — so
    /// reporting only the cloud reason would send them chasing an endpoint that is half the story,
    /// and the recovery entry it produces would fail its retry the same way.
    @Test func bothLegsFailingReportsBothReasons() async {
        let engine = FallbackSTTEngine(
            primary: STTSpy(result: .failure(NamedError(text: "cloud is down")), name: "Cloud STT"),
            fallback: STTSpy(result: .failure(NamedError(text: "no model downloaded")), name: "WhisperKit"),
            skipsPrimary: false
        )

        await #expect(throws: FallbackSTTEngine.BothEnginesFailed.self) {
            _ = try await transcribe(engine)
        }
        do {
            _ = try await transcribe(engine)
        } catch {
            #expect(error.localizedDescription.contains("cloud is down"))
            #expect(error.localizedDescription.contains("no model downloaded"))
        }
    }

    /// A stop the user cancelled must not be answered with a second transcription.
    @Test func cancellationIsNeverRetriedLocally() async {
        let local = STTSpy(result: .success("local"))
        let engine = FallbackSTTEngine(
            primary: STTSpy(result: .failure(CancellationError()), name: "Cloud STT"),
            fallback: local, skipsPrimary: false
        )

        await #expect(throws: CancellationError.self) { _ = try await transcribe(engine) }
        #expect(await local.callCount == 0)
    }

    /// `decoderBiasVocabulary` decides before the call, with no way to know which leg will run. If
    /// the wrapper reported only the cloud's "costs nothing", a fallback would hand WhisperKit the
    /// full vocabulary as `promptTokens` — one decoder inference per term per 30 s window, paid on
    /// the one dictation already running late.
    @Test func biasCostIsClaimedWhenEitherLegPaysForIt() {
        let engine = FallbackSTTEngine(
            primary: CloudSTTEngine(), fallback: WhisperKitEngine(), skipsPrimary: false
        )

        #expect(CloudSTTEngine().vocabularyBiasCostsDecodeTime == false)
        #expect(engine.vocabularyBiasCostsDecodeTime)
        #expect(AppCoordinator.decoderBiasVocabulary(
            ["Qdrant"], refinementCarriesVocabulary: true,
            biasCostsDecodeTime: engine.vocabularyBiasCostsDecodeTime
        ) == [])
    }

    @Test func theConfiguredEngineIsStillTheOneNamedAndStatusReported() async {
        let engine = FallbackSTTEngine(
            primary: STTSpy(result: .success("cloud"), name: "Cloud STT"),
            fallback: STTSpy(result: .success("local"), name: "WhisperKit"),
            skipsPrimary: false
        )

        #expect(engine.name == "Cloud STT")
        #expect(await engine.statusText == "Ready")
    }

    // MARK: - The bounded cloud budget

    /// `timeoutInterval` is idle time, and server-side transcription is the dominant idle window,
    /// so the budget tracks the audio rather than sitting at a flat 300 s a dead endpoint spends
    /// in full.
    @Test(arguments: [
        (0.0, 30.0), (10.0, 30.0), (60.0, 120.0), (63.5, 127.0), (200.0, 300.0), (3_600.0, 300.0)
    ])
    func theCloudBudgetTracksTheAudioBetweenAFloorAndTheOldCeiling(
        _ audioSeconds: Double, _ expected: Double
    ) {
        #expect(CloudSTTEngine.transcribeTimeout(audioSeconds: audioSeconds) == expected)
    }
}

private struct NamedError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

private actor STTSpy: TranscriptionEngine {
    enum Result {
        case success(String)
        case failure(any Error)
    }

    nonisolated let name: String
    nonisolated var statusText: String { "Ready" }
    nonisolated let vocabularyBiasCostsDecodeTime = false
    private let result: Result
    private(set) var callCount = 0

    init(result: Result, name: String = "Spy") {
        self.result = result
        self.name = name
    }

    func transcribe(samples: [Float], forcedLanguage: String?, candidateLanguages: [String], vocabulary: [String]) async throws -> TranscriptionOutput {
        callCount += 1
        switch result {
        case .success(let text): return TranscriptionOutput(text: text, language: "en")
        case .failure(let error): throw error
        }
    }
}
