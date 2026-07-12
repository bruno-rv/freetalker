import Foundation
import Combine
import Testing
@testable import FreeTalker

@Suite @MainActor struct LibraryTranslationTests {
    @Test func usesRefinedFirstAndRawWhenRefinedIsBlank() async throws {
        let service = TranslationSpy(results: [.success("traduit"), .success("traduzido")])
        let store = VariantStoreSpy()
        let controller = makeController(service: service, store: store)
        controller.selectEntry(id: 7)

        controller.translate(entry: entry(refined: "refined"), to: .french)
        await controller.waitForCurrentRequest()
        controller.translate(entry: entry(refined: "  \n"), to: .portuguese)
        await controller.waitForCurrentRequest()

        #expect(await service.sources == ["refined", "raw"])
    }

    @Test func supportsEveryNamedTargetAndCapturesOneFreshSnapshotPerRequest() async {
        let service = TranslationSpy(results: TranslationTarget.allCases.map { .success($0.rawValue) })
        let store = VariantStoreSpy()
        var snapshots = 0
        let controller = makeController(service: service, store: store) {
            snapshots += 1
            return Self.snapshot
        }

        for target in TranslationTarget.allCases {
            let current = entry(id: Int64(snapshots + 1))
            controller.selectEntry(id: current.id)
            controller.translate(entry: current, to: target)
            await controller.waitForCurrentRequest()
        }

        #expect(await service.targets == TranslationTarget.allCases)
        #expect(snapshots == TranslationTarget.allCases.count + 1) // initial availability + one per request
    }

    @Test func existingTargetRequiresConfirmationBeforeSnapshotOrMutation() async {
        let existing = variant(target: .spanish, text: "viejo")
        let service = TranslationSpy(results: [.success("nuevo")])
        let store = VariantStoreSpy(variants: [existing])
        var snapshots = 0
        let controller = makeController(service: service, store: store) {
            snapshots += 1
            return Self.snapshot
        }
        controller.selectEntry(id: 7)

        controller.translate(entry: entry(), to: .spanish)

        #expect(controller.pendingReplacementTarget == .spanish)
        #expect(snapshots == 1) // initial availability only
        #expect(store.upserts.isEmpty)

        controller.confirmReplacement()
        await controller.waitForCurrentRequest()

        #expect(snapshots == 2)
        #expect(store.upserts.map(\.text) == ["nuevo"])
        #expect(controller.variants.map(\.text) == ["nuevo"])
    }

    @Test func cancellationAndLateResponseCannotOverwriteNewerGeneration() async {
        let first = Gate()
        let service = TranslationSpy(results: [
            .gated(first, "late"),
            .success("new")
        ])
        let store = VariantStoreSpy()
        let controller = makeController(service: service, store: store)
        controller.selectEntry(id: 7)

        controller.translate(entry: entry(), to: .french)
        await first.waitUntilStarted()
        controller.cancel()
        controller.translate(entry: entry(), to: .german)
        await controller.waitForCurrentRequest()
        await first.release()
        await Task.yield()

        #expect(store.upserts.map(\.target) == [.german])
        #expect(controller.variants.map(\.target) == [.german])
        #expect(!controller.isTranslating)
    }

    @Test func emptyErrorAndDeletedParentLeaveExistingVariantsUnchanged() async {
        let old = variant(target: .french, text: "ancien")
        let service = TranslationSpy(results: [
            .failure(TranslationService.Error.emptyOutput),
            .failure(TestError.failed),
            .success("neu")
        ])
        let store = VariantStoreSpy(variants: [old])
        let controller = makeController(service: service, store: store)
        controller.selectEntry(id: 7)

        controller.translate(entry: entry(), to: .german)
        await controller.waitForCurrentRequest()
        #expect(controller.variants == [old])
        #expect(controller.errorMessage != nil)

        controller.translate(entry: entry(), to: .hindi)
        await controller.waitForCurrentRequest()
        #expect(controller.variants == [old])

        store.parentExists = false
        controller.translate(entry: entry(), to: .portuguese)
        await controller.waitForCurrentRequest()
        #expect(controller.variants == [old])
        #expect(store.upserts.isEmpty)
    }

    @Test func retryUsesFailedTargetAndAFreshSnapshot() async {
        let service = TranslationSpy(results: [.failure(TestError.failed), .success("traduit")])
        let store = VariantStoreSpy()
        var snapshots = 0
        let controller = makeController(service: service, store: store) {
            snapshots += 1
            return Self.snapshot
        }
        let original = entry()
        controller.selectEntry(id: original.id)

        controller.translate(entry: original, to: .french)
        await controller.waitForCurrentRequest()
        controller.retry(entry: original)
        await controller.waitForCurrentRequest()

        #expect(await service.targets == [.french, .french])
        #expect(snapshots == 3) // initial availability + two requests
        #expect(controller.variants.map(\.text) == ["traduit"])
    }

    @Test func originalAndVariantSelectionCopyIsExplicitAndNonMutating() throws {
        let translated = variant(target: .french, text: "traduit")
        let store = VariantStoreSpy(variants: [translated])
        var copied: [String] = []
        let controller = makeController(
            service: TranslationSpy(results: []),
            store: store,
            copy: { copied.append($0) }
        )
        let original = entry(refined: "original")
        controller.selectEntry(id: original.id)

        #expect(controller.displayedText(for: original) == "original")
        controller.select(.variant(.french))
        #expect(controller.displayedText(for: original) == "traduit")
        try controller.copyDisplayedText(for: original)

        #expect(copied == ["traduit"])
        #expect(store.upserts.isEmpty)
        #expect(original.refined == "original")
        #expect(original.transcript == "raw")
    }

    @Test func unavailablePresentationUsesCanonicalHelpAndCloudDisclosure() {
        let availability = CloudFeatureAvailability.make(
            eligibility: .missingAPIKey,
            provider: .anthropic
        )
        let presentation = LibraryTranslationPresentation(availability: availability)

        #expect(!presentation.isEnabled)
        #expect(presentation.tooltip == availability.tooltip)
        #expect(presentation.accessibilityHelp == availability.accessibilityHelp)
        #expect(presentation.privacyDisclosure == CloudPrivacyDisclosure.library)
        #expect(presentation.targets == TranslationTarget.allCases)
    }

    @Test func selectingAnotherEntryClearsConfirmationErrorRetryAndIgnoresLateResponse() async {
        let gate = Gate()
        let service = TranslationSpy(results: [.gated(gate, "late")])
        let existing = variant(target: .french, text: "old")
        let store = VariantStoreSpy(variants: [existing])
        let controller = makeController(service: service, store: store)
        controller.selectEntry(id: 7)
        controller.translate(entry: entry(), to: .french)
        #expect(controller.pendingReplacementTarget == .french)
        controller.dismissReplacement()
        store.variants = []
        controller.translate(entry: entry(), to: .german)
        await gate.waitUntilStarted()

        controller.selectEntry(id: 8)
        await gate.release()
        await Task.yield()

        #expect(controller.selection == .original)
        #expect(controller.pendingReplacementTarget == nil)
        #expect(controller.errorMessage == nil)
        #expect(!controller.canRetry)
        #expect(controller.variants.isEmpty)
        #expect(store.upserts.isEmpty)
    }

    @Test func availabilityTracksConfigurationAndCredentialUpdates() async {
        let configuration = PassthroughSubject<Void, Never>()
        let credentials = PassthroughSubject<Void, Never>()
        let current = SnapshotBox(Self.snapshot)
        let controller = LibraryTranslationController(
            translator: TranslationSpy(results: []), store: VariantStoreSpy(),
            snapshot: { current.value }, copy: { _ in },
            cloudConfigurationUpdates: configuration.eraseToAnyPublisher(),
            cloudCredentialUpdates: credentials.eraseToAnyPublisher()
        )
        #expect(controller.availability.enabled)
        current.value = CloudLLMSettingsSnapshot(provider: .anthropic, baseURL: "https://api.anthropic.com", model: "m", key: nil, vocabulary: [])
        credentials.send()
        await Task.yield()
        #expect(!controller.availability.enabled)
        current.value = Self.snapshot
        configuration.send()
        await Task.yield()
        #expect(controller.availability.enabled)
    }

    @Test func concurrentWriteRequiresExactReconfirmationWithoutARefresh() async {
        let first = variant(target: .french, text: "concurrent-one")
        var second = first
        second.text = "concurrent-two"
        second.updatedAt = first.updatedAt.addingTimeInterval(1)
        let store = VariantStoreSpy(forcedResults: [
            .replacementConfirmationRequired(first),
            .replacementConfirmationRequired(second)
        ])
        let controller = makeController(service: TranslationSpy(results: [.success("mine")]), store: store)
        let original = entry()
        controller.selectEntry(id: original.id)

        controller.translate(entry: original, to: .french)
        await controller.waitForCurrentRequest()
        #expect(controller.pendingReplacementTarget == .french)
        controller.confirmReplacement()

        #expect(controller.pendingReplacementTarget == .french)
        #expect(controller.variants.first == second)
        #expect(store.readCount == 1)
    }

    @Test func committedResultUpdatesCacheEvenWhenSubsequentReadsWouldFail() async {
        let store = VariantStoreSpy()
        store.failReadsAfter = 1
        let controller = makeController(service: TranslationSpy(results: [.success("saved")]), store: store)
        let original = entry()
        controller.selectEntry(id: original.id)
        controller.translate(entry: original, to: .german)
        await controller.waitForCurrentRequest()

        #expect(controller.variants.map(\.text) == ["saved"])
        #expect(controller.errorMessage == nil)
        #expect(store.readCount == 1)
    }

    @Test func libraryFocusLifecycleOffersCopyOnlyAndNeverTargetedInsert() {
        let presentation = LibraryTranslationPresentation(availability: .make(
            eligibility: .eligible(apiKey: nil), provider: .openAICompatible
        ))
        #expect(presentation.textActions == [.copy])
    }

    @Test func deletionAfterConfirmationClearsStaleVariantAndRetryUsesAbsentExpectation() async {
        let existing = variant(target: .french, text: "old")
        let store = VariantStoreSpy(
            variants: [existing],
            forcedResults: [.replacementStateChangedToAbsent]
        )
        let service = TranslationSpy(results: [.success("first"), .success("retry")])
        let controller = makeController(service: service, store: store)
        let original = entry()
        controller.selectEntry(id: original.id)
        controller.translate(entry: original, to: .french)
        controller.confirmReplacement()
        await controller.waitForCurrentRequest()

        #expect(controller.variants.isEmpty)
        #expect(controller.pendingReplacementTarget == nil)
        #expect(controller.canRetry)

        controller.retry(entry: original)
        await controller.waitForCurrentRequest()
        #expect(store.upserts.last?.text == "retry")
        #expect(controller.variants.map(\.text) == ["retry"])
    }

    private func makeController(
        service: TranslationSpy,
        store: VariantStoreSpy,
        snapshot: @escaping @MainActor () -> CloudLLMSettingsSnapshot = { Self.snapshot },
        copy: @escaping @MainActor (String) throws -> Void = { _ in }
    ) -> LibraryTranslationController {
        LibraryTranslationController(
            translator: service,
            store: store,
            snapshot: snapshot,
            copy: copy
        )
    }

    private func entry(id: Int64 = 7, refined: String = "refined") -> Dictation {
        Dictation(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1),
            sourceLanguage: SourceLanguage("en"),
            requestedOutputLanguage: .sameAsSpoken,
            templateName: "Clean",
            transcript: "raw",
            refined: refined,
            engine: "local",
            sourceID: nil
        )
    }

    private func variant(target: TranslationTarget, text: String) -> DictationTranslationVariant {
        DictationTranslationVariant(
            parentID: 7,
            target: target,
            text: text,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private static let snapshot = CloudLLMSettingsSnapshot(
        provider: .openAICompatible,
        baseURL: "http://localhost:1234/v1",
        model: "test-model",
        key: nil,
        vocabulary: []
    )
}

private enum TestError: Error { case failed }

@MainActor private final class SnapshotBox {
    var value: CloudLLMSettingsSnapshot
    init(_ value: CloudLLMSettingsSnapshot) { self.value = value }
}

private final class VariantStoreSpy: LibraryTranslationStoring {
    struct Upsert { let parentID: Int64; let target: TranslationTarget; let text: String }
    var variants: [DictationTranslationVariant]
    var upserts: [Upsert] = []
    var parentExists = true
    var forcedResults: [TranslationVariantWriteResult]
    var readCount = 0
    var failReadsAfter: Int?

    init(variants: [DictationTranslationVariant] = [], forcedResults: [TranslationVariantWriteResult] = []) {
        self.variants = variants
        self.forcedResults = forcedResults
    }

    func translationVariants(parentID: Int64) throws -> [DictationTranslationVariant] {
        readCount += 1
        if let failReadsAfter, readCount > failReadsAfter { throw TestError.failed }
        return variants
    }

    func conditionalUpsertTranslation(parentID: Int64, target: TranslationTarget, text: String, expected: TranslationVariantExpectation) throws -> TranslationVariantWriteResult {
        guard parentExists else { throw DatabaseError.translationParentMissing(parentID) }
        if !forcedResults.isEmpty {
            let result = forcedResults.removeFirst()
            if result == .replacementStateChangedToAbsent {
                variants.removeAll { $0.parentID == parentID && $0.target == target }
            }
            return result
        }
        if let current = variants.first(where: { $0.parentID == parentID && $0.target == target }) {
            guard case .version(current.updatedAt) = expected else { return .replacementConfirmationRequired(current) }
        } else if case .version = expected {
            throw DatabaseError.sqlFailed("changed")
        }
        upserts.append(.init(parentID: parentID, target: target, text: text))
        let now = Date()
        if let index = variants.firstIndex(where: { $0.parentID == parentID && $0.target == target }) {
            variants[index].text = text
            variants[index].updatedAt = now
            return .committed(variants[index])
        } else {
            let variant = DictationTranslationVariant(parentID: parentID, target: target, text: text, createdAt: now, updatedAt: now)
            variants.append(variant)
            return .committed(variant)
        }
    }
}

private actor TranslationSpy: Translating {
    enum Result {
        case success(String)
        case failure(any Error)
        case gated(Gate, String)
    }

    private var results: [Result]
    private(set) var sources: [String] = []
    private(set) var targets: [TranslationTarget] = []

    init(results: [Result]) { self.results = results }

    func process(
        source: String,
        template: Template,
        policy: OutputProcessingPolicy,
        snapshot: CloudLLMSettingsSnapshot
    ) async throws -> String {
        sources.append(source)
        if case .translate(let target) = policy { targets.append(target) }
        let result = results.removeFirst()
        switch result {
        case .success(let text): return text
        case .failure(let error): throw error
        case .gated(let gate, let text):
            await gate.startAndWait()
            return text
        }
    }
}

private actor Gate {
    private var started = false
    private var released = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func startAndWait() async {
        started = true
        startContinuations.forEach { $0.resume() }
        startContinuations.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseContinuations.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startContinuations.append($0) }
    }

    func release() {
        released = true
        releaseContinuations.forEach { $0.resume() }
        releaseContinuations.removeAll()
    }
}
