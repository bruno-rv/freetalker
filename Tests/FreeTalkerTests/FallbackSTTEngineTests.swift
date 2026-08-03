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
            fallback: local, skipsPrimary: false, refinementCarriesVocabulary: false
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
            skipsPrimary: false, refinementCarriesVocabulary: false
        )

        let output = try await transcribe(engine)

        #expect(output.text == "local")
        #expect(output.producedBy == "WhisperKit")
    }

    /// The Settings warning knows this base URL serves no `/audio/transcriptions`. Spending the
    /// whole timeout rediscovering that is the wait this removes. It reorders the legs rather than
    /// dropping the cloud one — see the last-resort tests below (Codex round 3, finding 5).
    @Test func aBaseURLThatServesNoTranscriptionEndpointGoesLocalFirst() async throws {
        let cloud = STTSpy(result: .success("cloud"), name: "Cloud STT")
        let engine = FallbackSTTEngine(
            primary: cloud, fallback: STTSpy(result: .success("local"), name: "WhisperKit"),
            skipsPrimary: true, refinementCarriesVocabulary: false
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
            skipsPrimary: false, refinementCarriesVocabulary: false
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
            skipsPrimary: true, refinementCarriesVocabulary: false
        )

        let output = try await transcribe(engine)

        #expect(output.text == "cloud")
        #expect(await cloud.callCount == 1)
    }

    @Test func aSkippedCloudThatAlsoFailsReportsBothReasons() async {
        let engine = FallbackSTTEngine(
            primary: STTSpy(result: .failure(NamedError(text: "cloud is down")), name: "Cloud STT"),
            fallback: STTSpy(result: .failure(NamedError(text: "no model downloaded")), name: "WhisperKit"),
            skipsPrimary: true, refinementCarriesVocabulary: false
        )

        do {
            _ = try await transcribe(engine)
            Issue.record("expected both legs to fail")
        } catch {
            #expect(error.localizedDescription.contains("cloud is down"))
            #expect(error.localizedDescription.contains("no model downloaded"))
        }
    }

    /// One flag cannot serve two legs, so the engine projects per leg instead: the cloud keeps the
    /// terms it carries for free, and WhisperKit is spared the decoder prompt the refinement will
    /// carry anyway (Codex round 3, finding 1). The last-resort cloud call is the case that made
    /// this necessary — it must not inherit a list emptied on the local engine's behalf.
    @Test func eachLegIsBiasedWithWhatThatLegShouldReceive() async throws {
        let cloud = VocabularyWitness(name: "Cloud STT", costsDecodeTime: false, fails: true)
        let local = VocabularyWitness(name: "WhisperKit", costsDecodeTime: true, fails: false)
        let engine = FallbackSTTEngine(
            primary: cloud, fallback: local,
            skipsPrimary: false, refinementCarriesVocabulary: true
        )

        _ = try await transcribe(engine, vocabulary: ["Qdrant"])

        #expect(await cloud.received == ["Qdrant"])
        #expect(await local.received == [])
    }

    @Test func aLastResortCloudCallStillGetsTheVocabulary() async throws {
        let cloud = VocabularyWitness(name: "Cloud STT", costsDecodeTime: false, fails: false)
        let local = VocabularyWitness(name: "WhisperKit", costsDecodeTime: true, fails: true)
        let engine = FallbackSTTEngine(
            primary: cloud, fallback: local,
            skipsPrimary: true, refinementCarriesVocabulary: true
        )

        _ = try await transcribe(engine, vocabulary: ["Qdrant"])

        #expect(await local.received == [])
        #expect(await cloud.received == ["Qdrant"])
    }

    /// A Raw stop has no refinement to carry the terms, so neither leg is withheld from.
    @Test func aRawStopBiasesBothLegs() async throws {
        let cloud = VocabularyWitness(name: "Cloud STT", costsDecodeTime: false, fails: true)
        let local = VocabularyWitness(name: "WhisperKit", costsDecodeTime: true, fails: false)
        let engine = FallbackSTTEngine(
            primary: cloud, fallback: local,
            skipsPrimary: false, refinementCarriesVocabulary: false
        )

        _ = try await transcribe(engine, vocabulary: ["Qdrant"])

        #expect(await cloud.received == ["Qdrant"])
        #expect(await local.received == ["Qdrant"])
    }

    /// The caller must hand over the whole snapshot for the per-leg projection to have anything to
    /// project, which means the wrapper answers with the cloud's cost, not the local engine's.
    @Test func theWrapperAsksTheCallerToWithholdNothing() {
        let engine = FallbackSTTEngine(
            primary: CloudSTTEngine(), fallback: WhisperKitEngine(),
            skipsPrimary: true, refinementCarriesVocabulary: true
        )

        #expect(engine.vocabularyBiasCostsDecodeTime == false)
        #expect(AppCoordinator.decoderBiasVocabulary(
            ["Qdrant"], refinementCarriesVocabulary: true,
            biasCostsDecodeTime: engine.vocabularyBiasCostsDecodeTime
        ) == ["Qdrant"])
    }

    /// Codex round 2, finding 1. The cloud can return after the user has already abandoned the
    /// stop; delivering that would paste text into a dictation they cancelled, and flash a notice
    /// about it. The gate makes the ordering exact: the engine is inside the cloud call when the
    /// cancellation lands.
    @Test(.timeLimit(.minutes(1)))
    func aCloudSuccessThatArrivesAfterCancellationIsNotDelivered() async {
        let gate = Gate()
        let engine = FallbackSTTEngine(
            primary: STTSpy(result: .success("cloud"), name: "Cloud STT", gate: gate),
            fallback: STTSpy(result: .success("local"), name: "WhisperKit"),
            skipsPrimary: false, refinementCarriesVocabulary: false
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
            fallback: local, skipsPrimary: false, refinementCarriesVocabulary: false
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
            primary: CloudSTTEngine(), fallback: WhisperKitEngine(), skipsPrimary: false, refinementCarriesVocabulary: false
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
            skipsPrimary: false, refinementCarriesVocabulary: false
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
    /// bytes, so a total ceiling sits above the largest inactivity budget — flat, because the
    /// session that carries it is shared across dictations (round 3, finding 3).
    @Test(arguments: [0.0, 60.0, 200.0, 3_600.0])
    func theTotalCeilingIsNeverReachedBeforeTheInactivityBudget(_ audioSeconds: Double) {
        #expect(
            CloudSTTEngine.transcribeResourceTimeout
                >= CloudSTTEngine.transcribeTimeout(audioSeconds: audioSeconds) * 2
        )
    }
}

private struct NamedError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

/// Records the vocabulary its leg was actually handed, which is the whole point of the per-leg
/// projection — a leg's `vocabularyBiasCostsDecodeTime` is what decides what it should get.
private actor VocabularyWitness: TranscriptionEngine {
    nonisolated let name: String
    nonisolated var statusText: String { "Ready" }
    nonisolated let vocabularyBiasCostsDecodeTime: Bool
    private let fails: Bool
    private(set) var received: [String]?

    init(name: String, costsDecodeTime: Bool, fails: Bool) {
        self.name = name
        self.vocabularyBiasCostsDecodeTime = costsDecodeTime
        self.fails = fails
    }

    func transcribe(samples: [Float], forcedLanguage: String?, candidateLanguages: [String], vocabulary: [String]) async throws -> TranscriptionOutput {
        received = vocabulary
        if fails { throw NamedError(text: "\(name) failed") }
        return TranscriptionOutput(text: name, language: "en")
    }
}

/// Holds a spy inside its `transcribe` call until the test lets it out, so "the cancellation
/// landed while the engine was mid-call" is an ordering, not a race.
///
/// Both waits are cancellation-aware: a `.timeLimit` cancels the test's task, but a continuation
/// nobody resumes stays suspended through that, so the time limit alone would not end a hang
/// (Codex round 4, finding 1). Cancellation releases whatever is waiting instead.
private actor Gate {
    private var entered: CheckedContinuation<Void, Never>?
    private var isEntered = false
    private var opened: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func waitUntilEntered() async {
        guard !isEntered else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { entered = $0 }
        } onCancel: {
            Task { await self.releaseAll() }
        }
    }

    func enter() async {
        isEntered = true
        entered?.resume()
        entered = nil
        guard !isOpen else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { opened = $0 }
        } onCancel: {
            Task { await self.releaseAll() }
        }
    }

    func open() {
        isOpen = true
        opened?.resume()
        opened = nil
    }

    /// Resumes anything waiting and leaves the gate open, so a cancelled test unwinds instead of
    /// sitting on a continuation forever. Resuming twice would trap, hence the nil-out.
    private func releaseAll() {
        entered?.resume()
        entered = nil
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
