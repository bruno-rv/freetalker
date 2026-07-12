import Foundation
import Testing
@testable import FreeTalker

@MainActor
@Suite("Translation failure recovery", .serialized)
struct TranslationRecoveryTests {
    @Test func coordinatorNotifiesOpenScratchpadWhenFailureIsEnqueued() {
        let coordinator = AppCoordinator.shared
        Self.clearCoordinator(coordinator)
        let router = RecoveryPresentationRouterSpy(coordinator: coordinator)
        coordinator.translationRecoveryPresentationRouter = router
        defer {
            coordinator.translationRecoveryPresentationRouter = nil
            Self.clearCoordinator(coordinator)
        }

        _ = coordinator.handleOutputTranslationFailure(Self.failure(source: "new failure"))

        #expect(router.presentations.count == 1)
        #expect(router.presentations.last??.recoverableText == "new failure")
        #expect(router.presentations.last??.actionsEnabled == true)
    }

    @Test func coordinatorPublishesRetryInFlightThenAdvancesFIFOOnSuccess() async {
        let coordinator = AppCoordinator.shared
        Self.clearCoordinator(coordinator)
        let translator = SuspendedTranslationProbe()
        let router = RecoveryPresentationRouterSpy(coordinator: coordinator)
        coordinator.translationRecoveryPresentationRouter = router
        coordinator.configureTranslationRecoveryForTesting(
            snapshot: { Self.snapshot() },
            translate: translator.process,
            deliver: { _, _, _ in true }
        )
        defer {
            coordinator.resetTranslationRecoveryTestingConfiguration()
            coordinator.translationRecoveryPresentationRouter = nil
            Self.clearCoordinator(coordinator)
        }
        _ = coordinator.handleOutputTranslationFailure(Self.failure(source: "first"))
        _ = coordinator.handleOutputTranslationFailure(Self.failure(source: "second"))

        coordinator.retryNextTranslation()
        await translator.waitUntilCalled()
        await Self.waitUntil { router.presentations.last??.isRetrying == true }
        #expect(router.presentations.last??.actionsEnabled == false)

        await translator.resume(returning: "translated first")
        await Self.waitUntil { coordinator.nextTranslationRecoveryPresentation?.recoverableText == "second" }

        #expect(router.presentations.contains { $0?.isRetrying == true })
        #expect(router.presentations.last??.recoverableText == "second")
        #expect(router.presentations.last??.actionsEnabled == true)
        #expect(coordinator.pendingOutputTranslationFailures().map(\.source) == ["second"])
    }

    @Test func failedCoordinatorRetryKeepsSameActionableItemAndPublishesError() async {
        let coordinator = AppCoordinator.shared
        Self.clearCoordinator(coordinator)
        let router = RecoveryPresentationRouterSpy(coordinator: coordinator)
        coordinator.translationRecoveryPresentationRouter = router
        coordinator.configureTranslationRecoveryForTesting(
            snapshot: { Self.snapshot() },
            translate: TranslationProbe(error: ProbeError.failed).process,
            deliver: { _, _, _ in Issue.record("Must not deliver"); return true }
        )
        defer {
            coordinator.resetTranslationRecoveryTestingConfiguration()
            coordinator.translationRecoveryPresentationRouter = nil
            Self.clearCoordinator(coordinator)
        }
        let failure = Self.failure(source: "still here")
        _ = coordinator.handleOutputTranslationFailure(failure)

        coordinator.retryNextTranslation()
        await Self.waitUntil { coordinator.nextTranslationRecoveryPresentation?.errorText != nil }

        #expect(coordinator.pendingOutputTranslationFailures().map(\.id) == [failure.id])
        #expect(router.presentations.last??.recoverableText == "still here")
        #expect(router.presentations.last??.actionsEnabled == true)
        #expect(router.presentations.last??.errorText == "Translation failed. Try again.")
    }

    @Test func exactConsumeAndFinalSourceSuccessPublishAdvanceThenClear() async {
        let coordinator = AppCoordinator.shared
        Self.clearCoordinator(coordinator)
        let router = RecoveryPresentationRouterSpy(coordinator: coordinator)
        coordinator.translationRecoveryPresentationRouter = router
        coordinator.configureTranslationRecoveryForTesting(
            snapshot: { Self.snapshot() }, translate: TranslationProbe(output: "unused").process,
            deliver: { _, _, _ in true }
        )
        defer {
            coordinator.resetTranslationRecoveryTestingConfiguration()
            coordinator.translationRecoveryPresentationRouter = nil
            Self.clearCoordinator(coordinator)
        }
        let first = Self.failure(source: "first")
        let second = Self.failure(source: "second")
        _ = coordinator.handleOutputTranslationFailure(first)
        _ = coordinator.handleOutputTranslationFailure(second)

        _ = coordinator.consumePendingOutputTranslationFailure(id: first.id)
        #expect(router.presentations.last??.recoverableText == "second")

        coordinator.insertNextTranslationSource()
        await Self.waitUntil { coordinator.nextTranslationRecoveryPresentation == nil }
        #expect(router.presentations.last! == nil)
    }

    @Test func recordingHUDKeepsOwnershipWhenRetryCompletesAndPendingFIFOReappearsAfterTerminal() async {
        let coordinator = AppCoordinator.shared
        Self.clearCoordinator(coordinator)
        let translator = SuspendedTranslationProbe()
        coordinator.configureTranslationRecoveryForTesting(
            snapshot: { Self.snapshot() }, translate: translator.process,
            deliver: { _, _, _ in true }
        )
        defer {
            coordinator.recordingHUDDidReachTerminalState()
            coordinator.resetTranslationRecoveryTestingConfiguration()
            Self.clearCoordinator(coordinator)
        }
        _ = coordinator.handleOutputTranslationFailure(Self.failure(source: "first"))
        _ = coordinator.handleOutputTranslationFailure(Self.failure(source: "second"))
        #expect(coordinator.translationRecoveryHUDOwner == .recovery)

        coordinator.recordingHUDWillPresent()
        #expect(coordinator.translationRecoveryHUDOwner == .recording)
        coordinator.retryNextTranslation()
        await translator.waitUntilCalled()
        await translator.resume(returning: "translated")
        await Self.waitUntil { coordinator.nextTranslationRecoveryPresentation?.recoverableText == "second" }

        #expect(coordinator.translationRecoveryHUDOwner == .recording)
        coordinator.recordingHUDDidReachTerminalState()
        #expect(coordinator.translationRecoveryHUDOwner == .recovery)
        #expect(coordinator.nextTranslationRecoveryPresentation?.recoverableText == "second")
    }

    @Test func lateRecoveryEnqueueCannotReplaceRecordingHUD() {
        let coordinator = AppCoordinator.shared
        Self.clearCoordinator(coordinator)
        defer {
            coordinator.recordingHUDDidReachTerminalState()
            Self.clearCoordinator(coordinator)
        }
        coordinator.recordingHUDWillPresent()

        _ = coordinator.handleOutputTranslationFailure(Self.failure(source: "late"))

        #expect(coordinator.translationRecoveryHUDOwner == .recording)
        #expect(coordinator.nextTranslationRecoveryPresentation?.recoverableText == "late")
        coordinator.recordingHUDDidReachTerminalState()
        #expect(coordinator.translationRecoveryHUDOwner == .recovery)
    }

    @Test func staleRecordingTerminalCannotReleaseNewerHUDOwnership() {
        let coordinator = AppCoordinator.shared
        Self.clearCoordinator(coordinator)
        defer {
            coordinator.recordingHUDDidReachTerminalState()
            Self.clearCoordinator(coordinator)
        }
        _ = coordinator.handleOutputTranslationFailure(Self.failure(source: "pending"))
        let older = coordinator.recordingHUDWillPresent()
        _ = coordinator.recordingHUDWillPresent()

        coordinator.recordingHUDDidReachTerminalState(generation: older)

        #expect(coordinator.translationRecoveryHUDOwner == .recording)
    }

    @Test(arguments: [
        AppCoordinator.RecordingHUDEarlyTerminal.voiceEditEscape,
        .externalDeadAudio,
        .scratchpadDeadAudio,
    ])
    func earlyRecordingTerminalReleasesHUDAndNotifiesRecoveryRouter(
        terminal: AppCoordinator.RecordingHUDEarlyTerminal
    ) {
        let coordinator = AppCoordinator.shared
        Self.clearCoordinator(coordinator)
        let router = RecoveryPresentationRouterSpy(coordinator: coordinator)
        coordinator.translationRecoveryPresentationRouter = router
        defer {
            coordinator.translationRecoveryPresentationRouter = nil
            coordinator.recordingHUDDidReachTerminalState()
            Self.clearCoordinator(coordinator)
        }
        _ = coordinator.handleOutputTranslationFailure(Self.failure(source: "recover after terminal"))
        let generation = coordinator.recordingHUDWillPresent()

        coordinator.recordingHUDDidEndEarly(terminal, generation: generation)

        #expect(coordinator.translationRecoveryHUDOwner == .recovery)
        #expect(coordinator.nextTranslationRecoveryPresentation?.recoverableText == "recover after terminal")
        #expect(router.presentations.last??.recoverableText == "recover after terminal")
    }
    @Test func pendingRecoveryRetainsImmutableFailureInputs() {
        let token = ScratchpadInsertionToken(id: UUID())
        let context = Self.context(destination: .scratchpad(token))
        let failure = OutputTranslationFailure(
            source: "raw source", context: context, engineName: "Cloud STT",
            underlyingError: ProbeError.failed
        )

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

    @Test func externalRetryRecordsResolvedHistoryExactlyOnce() async {
        var records: [TranslationRecoveryHistoryRecord] = []
        var deliveries = 0
        let failure = Self.failure(source: "raw source")
        let controller = PendingTranslationRecoveryController(
            snapshot: { Self.snapshot(model: "fresh") },
            translate: { _, _, _, _ in "translated" },
            deliver: { _, _, _ in deliveries += 1; return true },
            recordResolved: { records.append($0) }
        )
        controller.enqueue(failure)

        await controller.retryTranslation(id: failure.id)

        #expect(deliveries == 1)
        #expect(records == [.init(
            rawTranscript: "raw source", finalOutput: "translated",
            sourceLanguage: SourceLanguage("en"), requestedOutputLanguage: .german,
            templateName: "Plain", engineName: "Cloud STT"
        )])
        #expect(controller.pendingRecoveries.isEmpty)
    }

    @Test func externalSourceRecoveryRecordsSourceAsFinalExactlyOnce() {
        var records: [TranslationRecoveryHistoryRecord] = []
        var deliveries = 0
        let failure = Self.failure(source: "raw source")
        let controller = PendingTranslationRecoveryController(
            snapshot: { Self.snapshot() },
            translate: { _, _, _, _ in "unused" },
            deliver: { _, _, _ in deliveries += 1; return true },
            recordResolved: { records.append($0) }
        )
        controller.enqueue(failure)

        controller.insertSourceText(id: failure.id)

        #expect(deliveries == 1)
        #expect(records.first?.rawTranscript == "raw source")
        #expect(records.first?.finalOutput == "raw source")
        #expect(records.first?.requestedOutputLanguage == .german)
        #expect(controller.pendingRecoveries.isEmpty)
    }

    @Test func historyFailureAfterDeliveryDoesNotRedeliverOrRetainRecovery() async {
        var deliveries = 0
        var historyErrors: [String] = []
        let failure = Self.failure(source: "raw")
        let controller = PendingTranslationRecoveryController(
            snapshot: { Self.snapshot() },
            translate: { _, _, _, _ in "translated" },
            deliver: { _, _, _ in deliveries += 1; return true },
            recordResolved: { _ in throw ProbeError.failed },
            onHistoryFailure: { historyErrors.append($0) }
        )
        controller.enqueue(failure)

        await controller.retryTranslation(id: failure.id)
        await controller.retryTranslation(id: failure.id)

        #expect(deliveries == 1)
        #expect(controller.pendingRecoveries.isEmpty)
        #expect(historyErrors == ["Library save failed"])
    }

    private static let template = Template(id: "plain", name: "Plain", prompt: "Clean")

    private static func context(destination: RecordingDestination = .external) -> RecordingProcessingContext {
        .init(destination: destination, spokenLanguage: "en", outputLanguage: .german,
              template: template, cloudSnapshot: snapshot(model: "stale"))
    }

    private static func failure(source: String, destination: RecordingDestination = .external) -> OutputTranslationFailure {
        .init(source: source, context: context(destination: destination), engineName: "Cloud STT", underlyingError: ProbeError.failed)
    }

    private static func snapshot(model: String = "model") -> CloudLLMSettingsSnapshot {
        .init(provider: .anthropic, baseURL: "https://example.com", model: model, key: "key", vocabulary: [])
    }

    private static func ineligibleSnapshot() -> CloudLLMSettingsSnapshot {
        .init(provider: .anthropic, baseURL: "", model: "", key: "", vocabulary: [])
    }

    private static func clearCoordinator(_ coordinator: AppCoordinator) {
        while coordinator.consumeNextPendingOutputTranslationFailure() != nil {}
    }

    private static func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        attempts: Int = 200
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Condition was not reached")
    }
}

@MainActor
private final class RecoveryPresentationRouterSpy: TranslationRecoveryPresentationRouting {
    private unowned let coordinator: AppCoordinator
    private(set) var presentations: [TranslationRecoveryPresentation?] = []

    init(coordinator: AppCoordinator) { self.coordinator = coordinator }

    func translationRecoveryPresentationDidChange() {
        presentations.append(coordinator.nextTranslationRecoveryPresentation)
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
