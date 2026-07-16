import AppKit
import Foundation
import Testing
@testable import FreeTalker

@Suite("Scratchpad Translate")
struct ScratchpadTranslateTests {

    @Test func translateActionHasTranslateLabel() {
        #expect(ScratchpadAIAction.translate(.french).label == "Translate")
    }

    @Test(arguments: TranslationTarget.allCases)
    func translatePromptContainsTargetDirectiveAndOmitsSameLanguageRule(target: TranslationTarget) async throws {
        let spy = TranslateRequestSpy(response: "translated")
        let service = ScratchpadTransformationService(process: spy.process)

        _ = try await service.transform("Texto original", action: .translate(target), snapshot: Self.eligibleSnapshot())

        let request = try #require(await spy.request)
        #expect(request.template.prompt.contains("Translate the result to \(target.promptName)."))
        #expect(request.template.prompt.localizedCaseInsensitiveContains("same language as the input") == false)
        #expect(request.languagePolicy == .translate(to: target))
    }

    @Test(arguments: [
        ScratchpadAIAction.improveWriting, .expand, .condense, .custom("Make it punchy"),
    ])
    func nonTranslateActionsKeepPreserveSourcePolicyAndSameLanguageRule(action: ScratchpadAIAction) async throws {
        let spy = TranslateRequestSpy(response: "result")
        let service = ScratchpadTransformationService(process: spy.process)

        _ = try await service.transform("input", action: action, snapshot: Self.eligibleSnapshot())

        let request = try #require(await spy.request)
        #expect(request.languagePolicy == .preserveSource)
        #expect(request.template.prompt.contains("Respond in the same language as the input."))
    }

    @MainActor @Test func translateReplacesSourceOnSuccess() async {
        let harness = TranslateWindowHarness(outcome: "Bonjour le monde")
        harness.controller.scratchpadDocument.textStorage.append(NSAttributedString(string: "Hello world"))

        harness.controller.performAIAction(.translate(.french))
        await harness.waitForCompletion()

        #expect(harness.controller.scratchpadDocument.textStorage.string == "Bonjour le monde")
        #expect(await harness.spy.requests.first?.action == .translate(.french))
    }

    @MainActor @Test func translateCancellationOnCloseLeavesSourceUntouched() async {
        let service = ControlledTranslateTransformer()
        let harness = TranslateWindowHarness(service: service)
        harness.controller.scratchpadDocument.textStorage.append(NSAttributedString(string: "original"))

        harness.controller.performAIAction(.translate(.spanish))
        await service.waitForRequestCount(1)

        harness.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(!harness.controller.scratchpadView.isAIInFlight)

        await service.finish(0, with: "stale translation")
        await Task.yield()

        #expect(harness.controller.scratchpadDocument.textStorage.string == "original")
    }

    @MainActor @Test func translateIsAvailableWithoutInstructionWhileCustomStillRequiresOne() {
        let view = ScratchpadView(document: ScratchpadDocument(url: Self.tempURL()))
        let snapshot = Self.eligibleSnapshot()

        view.updateAIAvailability(snapshot: snapshot, hasInput: true)

        #expect(view.translateButton.isEnabled)
        let custom = view.aiButtons[3]
        #expect(!custom.isEnabled)

        view.customInstruction = "Make it formal"
        view.updateAIAvailability(snapshot: snapshot, hasInput: true)
        #expect(custom.isEnabled)
    }

    @MainActor @Test func translateUnavailableWithoutInputLikeOtherActions() {
        let view = ScratchpadView(document: ScratchpadDocument(url: Self.tempURL()))
        view.updateAIAvailability(snapshot: Self.eligibleSnapshot(), hasInput: false)
        #expect(!view.translateButton.isEnabled)
    }

    @MainActor @Test func translateDropdownSelectionInvokesOnAIActionWithChosenTarget() {
        let view = ScratchpadView(document: ScratchpadDocument(url: Self.tempURL()))
        var received: ScratchpadAIAction?
        view.onAIAction = { received = $0 }

        let index = TranslationTarget.allCases.firstIndex(of: .german)!
        view.translateButton.selectItem(at: index + 1)
        _ = view.translateButton.sendAction(view.translateButton.action, to: view.translateButton.target)

        #expect(received == .translate(.german))
    }

    @MainActor @Test func translateDropdownHasAllEightTargets() {
        let view = ScratchpadView(document: ScratchpadDocument(url: Self.tempURL()))
        // Item 0 is the fixed "Translate" title; the remaining items are the 8 targets.
        #expect(view.translateButton.numberOfItems == TranslationTarget.allCases.count + 1)
    }

    private static func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("rtf")
    }

    private static func eligibleSnapshot() -> CloudLLMSettingsSnapshot {
        CloudLLMSettingsSnapshot(provider: .openAICompatible, baseURL: "http://localhost:1234/v1", model: "model", key: nil, vocabulary: [])
    }
}

private actor TranslateRequestSpy {
    struct Request: Sendable {
        let template: Template
        let languagePolicy: OutputProcessingPolicy
    }

    let response: String
    private(set) var request: Request?

    init(response: String) { self.response = response }

    func process(_ request: PostProcessingRequest, snapshot: CloudLLMSettingsSnapshot) async throws -> String {
        self.request = Request(template: request.template, languagePolicy: request.languagePolicy)
        return response
    }
}

private actor TranslateTransformSpy: ScratchpadTransforming {
    struct Request { let action: ScratchpadAIAction }

    let response: String
    private(set) var requests: [Request] = []

    init(response: String) { self.response = response }

    func transform(_ text: String, action: ScratchpadAIAction, snapshot: CloudLLMSettingsSnapshot) async throws -> String {
        requests.append(.init(action: action))
        return response
    }
}

private actor ControlledTranslateTransformer: ScratchpadTransforming {
    private var continuations: [CheckedContinuation<String, Never>] = []
    private var requestCount = 0

    func transform(_ text: String, action: ScratchpadAIAction, snapshot: CloudLLMSettingsSnapshot) async throws -> String {
        requestCount += 1
        return await withCheckedContinuation { continuations.append($0) }
    }

    func waitForRequestCount(_ expected: Int) async {
        while requestCount < expected { await Task.yield() }
    }

    func finish(_ index: Int, with result: String) {
        continuations[index].resume(returning: result)
    }
}

@MainActor
private final class TranslateWindowHarness {
    let controller: ScratchpadWindowController
    let spy: TranslateTransformSpy

    init(outcome successText: String) {
        spy = TranslateTransformSpy(response: successText)
        controller = Self.makeController(service: spy)
    }

    init(service: any ScratchpadTransforming) {
        spy = TranslateTransformSpy(response: "unused")
        controller = Self.makeController(service: service)
    }

    private static func makeController(service: any ScratchpadTransforming) -> ScratchpadWindowController {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("rtf")
        return ScratchpadWindowController(
            documentURL: url,
            startRecording: { _ in false }, recordingIsBusy: { false }, stopRecording: {}, registerRouter: { _ in },
            pendingRecordings: { [] }, consumePendingRecording: { _ in nil }, clearPendingRecording: { _ in }, consumePendingFailure: { nil },
            flushDocument: { _ in }, transformationService: service,
            cloudLLMSnapshot: {
                CloudLLMSettingsSnapshot(provider: .openAICompatible, baseURL: "http://localhost:1234/v1", model: "model", key: nil, vocabulary: [])
            }
        )
    }

    func waitForCompletion() async {
        for _ in 0..<100 where controller.scratchpadView.isAIInFlight { await Task.yield() }
    }
}
