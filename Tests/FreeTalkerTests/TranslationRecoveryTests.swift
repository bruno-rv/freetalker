import Foundation
import Testing
@testable import FreeTalker

@MainActor
@Suite("Translation failure recovery")
struct TranslationRecoveryTests {
    @Test func pendingRecoveryRetainsImmutableFailureInputs() {
        let token = ScratchpadInsertionToken(id: UUID())
        let context = Self.context(destination: .scratchpad(token))
        let failure = OutputTranslationFailure(source: "raw source", context: context, underlyingError: ProbeError.failed)

        let recovery = PendingTranslationRecovery(failure: failure)

        #expect(recovery.failureID == failure.id)
        #expect(recovery.sourceTranscript == "raw source")
        #expect(recovery.sourceLanguage == "en")
        #expect(recovery.outputLanguage == .german)
        #expect(recovery.template == Self.template)
        #expect(recovery.destination == .scratchpad(token))
    }

    @Test func retryCapturesFreshEligibleSnapshotOnlyWhenInvokedAndUsesRetainedInputsOnce() async {
        let translator = TranslationProbe(output: "ubersetzt")
        var snapshotReads = 0
        var delivered: [(String, RecordingDestination)] = []
        let controller = PendingTranslationRecoveryController(
            snapshot: { snapshotReads += 1; return Self.snapshot(model: "fresh") },
            translate: translator.process,
            deliver: { text, destination, _ in delivered.append((text, destination)); return true }
        )
        let failure = Self.failure(source: "raw source")
        controller.enqueue(failure)
        #expect(snapshotReads == 0)

        await controller.retryTranslation(id: failure.id)

        #expect(snapshotReads == 1)
        #expect(await translator.calls == 1)
        #expect(await translator.source == "raw source")
        #expect(await translator.template == Self.template)
        #expect(await translator.policy == .translate(to: .german))
        #expect(await translator.snapshot?.model == "fresh")
        #expect(delivered.map(\.0) == ["ubersetzt"])
        #expect(controller.pendingRecoveries.isEmpty)
    }

    @Test func ineligibleRetryDoesNotRequestOrInsertAndKeepsSource() async {
        let translator = TranslationProbe(output: "unused")
        var deliveries = 0
        let controller = PendingTranslationRecoveryController(
            snapshot: { Self.ineligibleSnapshot() }, translate: translator.process,
            deliver: { _, _, _ in deliveries += 1; return true }
        )
        let failure = Self.failure(source: "keep me")
        controller.enqueue(failure)

        await controller.retryTranslation(id: failure.id)

        #expect(await translator.calls == 0)
        #expect(deliveries == 0)
        #expect(controller.pendingRecoveries.map(\.sourceTranscript) == ["keep me"])
        #expect(controller.presentation(for: failure.id)?.message == "Translation failed")
    }

    @Test func transportEmptyAndCancellationNeverAutomaticallyInsertSource() async {
        for error in [ProbeError.failed, TranslationService.Error.emptyOutput, CancellationError()] as [Error] {
            let translator = TranslationProbe(error: error)
            var deliveries = 0
            let controller = PendingTranslationRecoveryController(
                snapshot: { Self.snapshot() }, translate: translator.process,
                deliver: { _, _, _ in deliveries += 1; return true }
            )
            let failure = Self.failure(source: "source")
            controller.enqueue(failure)

            await controller.retryTranslation(id: failure.id)

            #expect(deliveries == 0)
            #expect(controller.pendingRecoveries.count == 1)
        }
    }

    @Test func insertSourceIsExplicitUsesCapturedDestinationAndConsumesExactFIFOItem() {
        let first = Self.failure(source: "first")
        let token = ScratchpadInsertionToken(id: UUID())
        let second = Self.failure(source: "second", destination: .scratchpad(token))
        var delivery: (String, RecordingDestination)?
        let controller = PendingTranslationRecoveryController(
            snapshot: { Self.snapshot() }, translate: TranslationProbe(output: "unused").process,
            deliver: { text, destination, _ in delivery = (text, destination); return true }
        )
        controller.enqueue(first)
        controller.enqueue(second)

        controller.insertSourceText(id: second.id)

        #expect(delivery?.0 == "second")
        #expect(delivery?.1 == .scratchpad(token))
        #expect(controller.pendingRecoveries.map(\.failureID) == [first.id])
    }

    @Test func unsafeDestinationPreservesTextForManualRecovery() {
        let failure = Self.failure(source: "copy me")
        var attemptedDestination: RecordingDestination?
        let controller = PendingTranslationRecoveryController(
            snapshot: { Self.snapshot() }, translate: TranslationProbe(output: "unused").process,
            deliver: { _, destination, _ in attemptedDestination = destination; return false }
        )
        controller.enqueue(failure)

        controller.insertSourceText(id: failure.id)

        #expect(attemptedDestination == .external)
        #expect(controller.pendingRecoveries.map(\.recoverableText) == ["copy me"])
    }

    @Test func lateRetryResponseCannotResolveNewGeneration() async {
        let translator = SuspendedTranslationProbe()
        var deliveries: [String] = []
        let controller = PendingTranslationRecoveryController(
            snapshot: { Self.snapshot() }, translate: translator.process,
            deliver: { text, _, _ in deliveries.append(text); return true }
        )
        let failure = Self.failure(source: "source")
        controller.enqueue(failure)

        let first = Task { await controller.retryTranslation(id: failure.id) }
        await translator.waitUntilCalled()
        controller.invalidateAttempt(id: failure.id)
        await translator.resume(returning: "late")
        await first.value

        #expect(deliveries.isEmpty)
        #expect(controller.pendingRecoveries.count == 1)
    }

    @Test func sourceButtonLabelMakesTranslationBypassExplicit() {
        #expect(TranslationRecoveryPresentation.sourceActionTitle(outputLanguage: .german) == "Use source text")
        #expect(TranslationRecoveryPresentation.sourceActionTitle(outputLanguage: .sameAsSpoken) == "Raw")
        #expect(TranslationRecoveryPresentation.retryTitle == "Retry translation")
    }

    private static let template = Template(id: "plain", name: "Plain", prompt: "Clean")

    private static func context(destination: RecordingDestination = .external) -> RecordingProcessingContext {
        .init(destination: destination, spokenLanguage: "en", outputLanguage: .german,
              template: template, cloudSnapshot: snapshot(model: "stale"))
    }

    private static func failure(source: String, destination: RecordingDestination = .external) -> OutputTranslationFailure {
        .init(source: source, context: context(destination: destination), underlyingError: ProbeError.failed)
    }

    private static func snapshot(model: String = "model") -> CloudLLMSettingsSnapshot {
        .init(provider: .anthropic, baseURL: "https://example.com", model: model, key: "key", vocabulary: [])
    }

    private static func ineligibleSnapshot() -> CloudLLMSettingsSnapshot {
        .init(provider: .anthropic, baseURL: "", model: "", key: "", vocabulary: [])
    }
}

private enum ProbeError: Error { case failed }

private actor TranslationProbe {
    private let output: String?
    private let error: Error?
    private(set) var calls = 0
    private(set) var source: String?
    private(set) var template: Template?
    private(set) var policy: OutputProcessingPolicy?
    private(set) var snapshot: CloudLLMSettingsSnapshot?

    init(output: String) { self.output = output; error = nil }
    init(error: Error) { output = nil; self.error = error }

    func process(source: String, template: Template, policy: OutputProcessingPolicy,
                 snapshot: CloudLLMSettingsSnapshot) async throws -> String {
        calls += 1
        self.source = source
        self.template = template
        self.policy = policy
        self.snapshot = snapshot
        if let error { throw error }
        return output!
    }
}

private actor SuspendedTranslationProbe {
    private var continuation: CheckedContinuation<String, Never>?
    private var calledContinuation: CheckedContinuation<Void, Never>?
    private var called = false

    func process(source: String, template: Template, policy: OutputProcessingPolicy,
                 snapshot: CloudLLMSettingsSnapshot) async throws -> String {
        called = true
        calledContinuation?.resume()
        calledContinuation = nil
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilCalled() async {
        if called { return }
        await withCheckedContinuation { calledContinuation = $0 }
    }

    func resume(returning value: String) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
