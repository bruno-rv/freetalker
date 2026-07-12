import Foundation
import Testing
@testable import FreeTalker

@MainActor
@Suite("Output translation pipeline")
struct OutputTranslationPipelineTests {
    @Test(arguments: [("en", "en"), ("pt", "pt"), ("fr", nil), (nil, nil)] as [(String?, String?)])
    func sttReceivesOnlySupportedSpokenHints(argument: (String?, String?)) async throws {
        let engine = PipelineEngineSpy(output: .init(text: "source", language: "en"))
        _ = try await AppCoordinator.shared.processDictation(
            samples: [0.5], engine: engine, engineName: "Spy", template: Self.template,
            forcedLanguage: argument.0, skipPostProcessing: true,
            insert: { _, _ in true }, record: { _ in }
        )

        #expect(await engine.forcedLanguages == [argument.1])
    }

    @Test func sameAsSpokenUsesActiveProcessorAndPreservesSourceMetadata() async throws {
        let processor = PipelinePostProcessorSpy(output: "clean source")
        var recorded: RecordingProcessingResult?

        let result = try await AppCoordinator.shared.processDictation(
            samples: [0.5], engine: PipelineEngineSpy(output: .init(text: "raw source", language: "pt")),
            engineName: "Spy", template: Self.template, outputLanguage: .sameAsSpoken,
            processor: processor, insert: { text, _ in text == "clean source" },
            record: { recorded = $0 }
        )

        #expect(result.rawTranscript == "raw source")
        #expect(result.finalOutput == "clean source")
        #expect(result.sourceLanguage == SourceLanguage("pt"))
        #expect(result.requestedOutputLanguage == .sameAsSpoken)
        #expect(recorded?.rawTranscript == "raw source")
        #expect(recorded?.finalOutput == "clean source")
        #expect(await processor.callCount == 1)
    }

    @Test func namedOutputCallsTranslationOnceWithCapturedSnapshotAndNeverActiveProcessor() async throws {
        let processor = PipelinePostProcessorSpy(output: "must not run")
        let translation = PipelineTranslationSpy(output: "translated")
        let snapshot = Self.snapshot(model: "captured-model")
        var inserted: String?
        var recorded: RecordingProcessingResult?

        let result = try await AppCoordinator.shared.processDictation(
            samples: [0.5], engine: PipelineEngineSpy(output: .init(text: "raw source", language: "en")),
            engineName: "Spy", template: Self.template, outputLanguage: .german,
            cloudSnapshot: snapshot, processor: processor, translator: translation,
            insert: { text, _ in inserted = text; return true }, record: { recorded = $0 }
        )

        #expect(result.finalOutput == "translated")
        #expect(inserted == "translated")
        #expect(recorded?.requestedOutputLanguage == .german)
        #expect(recorded?.sourceLanguage == SourceLanguage("en"))
        #expect(await translation.callCount == 1)
        #expect(await translation.snapshot == snapshot)
        #expect(await translation.policy == .translate(to: .german))
        #expect(await processor.callCount == 0)
    }

    @Test func translationFailureRetainsSourceAndContextAndDeliversNothing() async {
        let translation = PipelineTranslationSpy(error: PipelineStubError.failed)
        let context = RecordingProcessingContext(
            destination: .external, spokenLanguage: "en", outputLanguage: .french,
            template: Self.template, cloudSnapshot: Self.snapshot()
        )
        var insertCount = 0
        var recordCount = 0

        do {
            _ = try await AppCoordinator.shared.processDictation(
                samples: [0.5], engine: PipelineEngineSpy(output: .init(text: "raw source", language: "en")),
                engineName: "Spy", context: context, translator: translation,
                insert: { _, _ in insertCount += 1; return true },
                record: { _ in recordCount += 1 }
            )
            Issue.record("Expected unresolved translation failure")
        } catch let failure as OutputTranslationFailure {
            #expect(failure.source == "raw source")
            #expect(failure.context == context)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(insertCount == 0)
        #expect(recordCount == 0)
    }

    @Test func translationFailureIsNotClassifiedAsTranscriptionFailure() {
        let context = RecordingProcessingContext(
            destination: .external, spokenLanguage: "en", outputLanguage: .french,
            template: Self.template, cloudSnapshot: Self.snapshot()
        )
        let failure = OutputTranslationFailure(
            source: "raw source", context: context, underlyingError: PipelineStubError.failed
        )

        #expect(AppCoordinator.pipelineFailureKind(failure) == .translation)
        #expect(AppCoordinator.pipelineFailureKind(AppCoordinator.PipelineError.emptyTranscript) == .transcription)
    }

    @Test func coordinatorRetainsUnresolvedTranslationForTaskSeven() throws {
        let coordinator = AppCoordinator.shared
        let context = RecordingProcessingContext(
            destination: .external, spokenLanguage: "pt", outputLanguage: .english,
            template: Self.template, cloudSnapshot: Self.snapshot()
        )
        let failure = OutputTranslationFailure(
            source: "fonte", context: context, underlyingError: PipelineStubError.failed
        )

        coordinator.deferOutputTranslationFailure(failure)
        let retained = try #require(coordinator.takeDeferredOutputTranslationFailure())

        #expect(retained.source == "fonte")
        #expect(retained.context == context)
        #expect(coordinator.takeDeferredOutputTranslationFailure() == nil)
    }

    private static let template = Template(id: "plain", name: "Plain", prompt: "Clean it")

    private static func snapshot(model: String = "model") -> CloudLLMSettingsSnapshot {
        .init(provider: .anthropic, baseURL: "https://example.com", model: model, key: "key", vocabulary: [])
    }
}

private enum PipelineStubError: Error { case failed }

private actor PipelineEngineSpy: TranscriptionEngine {
    nonisolated let name = "Spy"
    nonisolated var statusText: String { "Ready" }
    private let output: TranscriptionOutput
    private(set) var forcedLanguages: [String?] = []

    init(output: TranscriptionOutput) { self.output = output }

    func transcribe(samples: [Float], forcedLanguage: String?) async throws -> TranscriptionOutput {
        forcedLanguages.append(forcedLanguage)
        return output
    }
}

private actor PipelinePostProcessorSpy: PostProcessor {
    private let output: String
    private(set) var callCount = 0

    init(output: String) { self.output = output }

    func process(_ request: PostProcessingRequest) async throws -> String {
        callCount += 1
        return output
    }
}

private actor PipelineTranslationSpy: Translating {
    private let output: String?
    private let error: Error?
    private(set) var callCount = 0
    private(set) var snapshot: CloudLLMSettingsSnapshot?
    private(set) var policy: OutputProcessingPolicy?

    init(output: String) { self.output = output; error = nil }
    init(error: Error) { output = nil; self.error = error }

    func process(
        source: String, template: Template, policy: OutputProcessingPolicy,
        snapshot: CloudLLMSettingsSnapshot
    ) async throws -> String {
        callCount += 1
        self.snapshot = snapshot
        self.policy = policy
        if let error { throw error }
        return output!
    }
}
