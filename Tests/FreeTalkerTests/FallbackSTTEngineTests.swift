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

    /// Codex round 2, finding 3. The skip reads the base URL at stop time and the request reads it
    /// again, so Settings edited in between can make the decision stale. An optimization must not
    /// be why a dictation is lost: a skipped cloud is still attempted when local has nothing.
    @Test func aSkippedCloudIsStillTriedWhenTheLocalEngineHasNothing() async throws {
        let cloud = STTSpy(result: .success("cloud"), name: "Cloud STT")
        let engine = FallbackSTTEngine(
            primary: cloud,
            fallback: STTSpy(result: .failure(NamedError(text: "no model downloaded")), name: "WhisperKit"),
            skipsPrimary: true
        )

        let output = try await transcribe(engine)

        #expect(output.text == "cloud")
        #expect(await cloud.callCount == 1)
    }

    @Test func aSkippedCloudThatAlsoFailsReportsBothReasons() async {
        let engine = FallbackSTTEngine(
            primary: STTSpy(result: .failure(NamedError(text: "cloud is down")), name: "Cloud STT"),
            fallback: STTSpy(result: .failure(NamedError(text: "no model downloaded")), name: "WhisperKit"),
            skipsPrimary: true
        )

        do {
            _ = try await transcribe(engine)
            Issue.record("expected both legs to fail")
        } catch {
            #expect(error.localizedDescription.contains("cloud is down"))
            #expect(error.localizedDescription.contains("no model downloaded"))
        }
    }

    /// With the cloud skipped the local leg is not a maybe, so the withholding rule applies to it
    /// exactly as it would without the wrapper (Codex round 2, finding 2).
    @Test func skippingTheCloudLetsTheLocalEngineAnswerForItsOwnBiasCost() {
        let engine = FallbackSTTEngine(
            primary: CloudSTTEngine(), fallback: WhisperKitEngine(), skipsPrimary: true
        )

        #expect(engine.vocabularyBiasCostsDecodeTime)
        #expect(AppCoordinator.decoderBiasVocabulary(
            ["Qdrant"], refinementCarriesVocabulary: true,
            biasCostsDecodeTime: engine.vocabularyBiasCostsDecodeTime
        ) == [])
    }

    /// Codex round 2, finding 1. The cloud can return after the user has already abandoned the
    /// stop; delivering that would paste text into a dictation they cancelled, and flash a notice
    /// about it. The gate makes the ordering exact: the engine is inside the cloud call when the
    /// cancellation lands.
    @Test func aCloudSuccessThatArrivesAfterCancellationIsNotDelivered() async {
        let gate = Gate()
        let engine = FallbackSTTEngine(
            primary: STTSpy(result: .success("cloud"), name: "Cloud STT", gate: gate),
            fallback: STTSpy(result: .success("local"), name: "WhisperKit"),
            skipsPrimary: false
        )

        let task = Task { try await transcribe(engine) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()

        await #expect(throws: CancellationError.self) { try await task.value }
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

    /// Codex round 1, finding 2. `decoderBiasVocabulary` decides before the call and cannot know
    /// which leg will run, so the wrapper answers for the cloud — the leg that runs on all but the
    /// failing dictations. Reporting the OR instead would strip the vocabulary from every
    /// successful cloud transcription, where biasing is free, to spare the rare fallback.
    @Test func wrappingTheCloudDoesNotCostItItsFreeVocabularyBias() {
        let engine = FallbackSTTEngine(
            primary: CloudSTTEngine(), fallback: WhisperKitEngine(), skipsPrimary: false
        )

        #expect(engine.vocabularyBiasCostsDecodeTime == false)
        #expect(WhisperKitEngine().vocabularyBiasCostsDecodeTime)
        #expect(AppCoordinator.decoderBiasVocabulary(
            ["Qdrant"], refinementCarriesVocabulary: true,
            biasCostsDecodeTime: engine.vocabularyBiasCostsDecodeTime
        ) == ["Qdrant"])
    }

    // MARK: - Saying that it happened

    @Test func anOrdinaryDictationClaimsNoSubstitution() {
        #expect(AppCoordinator.engineSubstitutionNotice(
            configured: "Cloud STT", actual: "Cloud STT"
        ) == nil)
    }

    @Test func aSubstitutionNamesBothEngines() throws {
        let notice = try #require(AppCoordinator.engineSubstitutionNotice(
            configured: "Cloud STT", actual: "WhisperKit"
        ))
        #expect(notice.contains("Cloud STT"))
        #expect(notice.contains("WhisperKit"))
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
        (0.0, 60.0), (10.0, 60.0), (60.0, 120.0), (63.5, 127.0), (200.0, 300.0), (3_600.0, 300.0)
    ])
    func theCloudBudgetTracksTheAudioBetweenAFloorAndTheOldCeiling(
        _ audioSeconds: Double, _ expected: Double
    ) {
        #expect(CloudSTTEngine.transcribeTimeout(audioSeconds: audioSeconds) == expected)
    }

    /// Codex round 1, finding 7: the floor must never abandon an endpoint sooner than an
    /// unconfigured request would, or a cold start becomes a fallback.
    @Test func theFloorIsNeverTighterThanAnUnconfiguredRequestsOwnDefault() {
        #expect(CloudSTTEngine.transcribeTimeout(audioSeconds: 0) >= URLRequest(
            url: URL(string: "https://example.com")!
        ).timeoutInterval)
    }

    /// Codex round 1, finding 6: inactivity alone bounds nothing against a server that dribbles
    /// bytes, so a total deadline sits at twice the inactivity budget. Asserted exactly — a 1.1x
    /// multiplier would satisfy "greater than" while bounding nothing in practice (round 2,
    /// finding 9).
    @Test(arguments: [0.0, 60.0, 200.0, 3_600.0])
    func theTotalDeadlineIsTwiceTheInactivityBudget(_ audioSeconds: Double) {
        #expect(
            CloudSTTEngine.transcribeResourceTimeout(audioSeconds: audioSeconds)
                == CloudSTTEngine.transcribeTimeout(audioSeconds: audioSeconds) * 2
        )
    }
}

private struct NamedError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

/// Holds a spy inside its `transcribe` call until the test lets it out, so "the cancellation
/// landed while the engine was mid-call" is an ordering, not a race.
private actor Gate {
    private var entered: CheckedContinuation<Void, Never>?
    private var isEntered = false
    private var opened: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func waitUntilEntered() async {
        guard !isEntered else { return }
        await withCheckedContinuation { entered = $0 }
    }

    func enter() async {
        isEntered = true
        entered?.resume()
        entered = nil
        guard !isOpen else { return }
        await withCheckedContinuation { opened = $0 }
    }

    func open() {
        isOpen = true
        opened?.resume()
        opened = nil
    }
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
    private let gate: Gate?
    private(set) var callCount = 0

    init(result: Result, name: String = "Spy", gate: Gate? = nil) {
        self.result = result
        self.name = name
        self.gate = gate
    }

    func transcribe(samples: [Float], forcedLanguage: String?, candidateLanguages: [String], vocabulary: [String]) async throws -> TranscriptionOutput {
        callCount += 1
        await gate?.enter()
        switch result {
        case .success(let text): return TranscriptionOutput(text: text, language: "en")
        case .failure(let error): throw error
        }
    }
}
