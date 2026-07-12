import Foundation
import Testing
@testable import FreeTalker

@Suite @MainActor struct LibraryTranslationTests {
    @Test func usesRefinedFirstAndRawWhenRefinedIsBlank() async throws {
        let service = TranslationSpy(results: [.success("traduit"), .success("traduzido")])
        let store = VariantStoreSpy()
        let controller = makeController(service: service, store: store)

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
            controller.translate(entry: entry(id: Int64(snapshots + 1)), to: target)
            await controller.waitForCurrentRequest()
        }

        #expect(await service.targets == TranslationTarget.allCases)
        #expect(snapshots == TranslationTarget.allCases.count)
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
        controller.loadVariants(parentID: 7)

        controller.translate(entry: entry(), to: .spanish)

        #expect(controller.pendingReplacementTarget == .spanish)
        #expect(snapshots == 0)
        #expect(store.upserts.isEmpty)

        controller.confirmReplacement()
        await controller.waitForCurrentRequest()

        #expect(snapshots == 1)
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
        controller.loadVariants(parentID: 7)

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

        controller.translate(entry: original, to: .french)
        await controller.waitForCurrentRequest()
        controller.retry(entry: original)
        await controller.waitForCurrentRequest()

        #expect(await service.targets == [.french, .french])
        #expect(snapshots == 2)
        #expect(controller.variants.map(\.text) == ["traduit"])
    }

    @Test func originalAndVariantSelectionCopyAndInsertAreExplicitAndNonMutating() throws {
        let translated = variant(target: .french, text: "traduit")
        let store = VariantStoreSpy(variants: [translated])
        var copied: [String] = []
        var inserted: [String] = []
        let controller = makeController(
            service: TranslationSpy(results: []),
            store: store,
            copy: { copied.append($0) },
            insert: { inserted.append($0) }
        )
        let original = entry(refined: "original")
        controller.loadVariants(parentID: original.id)

        #expect(controller.displayedText(for: original) == "original")
        controller.select(.variant(.french))
        #expect(controller.displayedText(for: original) == "traduit")
        try controller.copyDisplayedText(for: original)
        controller.insertDisplayedText(for: original)

        #expect(copied == ["traduit"])
        #expect(inserted == ["traduit"])
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
        #expect(presentation.privacyDisclosure == "Translation sends this text to the API endpoint configured under Cloud post-processing.")
        #expect(presentation.targets == TranslationTarget.allCases)
    }

    private func makeController(
        service: TranslationSpy,
        store: VariantStoreSpy,
        snapshot: @escaping @MainActor () -> CloudLLMSettingsSnapshot = { Self.snapshot },
        copy: @escaping @MainActor (String) throws -> Void = { _ in },
        insert: @escaping @MainActor (String) -> Void = { _ in }
    ) -> LibraryTranslationController {
        LibraryTranslationController(
            translator: service,
            store: store,
            snapshot: snapshot,
            copy: copy,
            insert: insert
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

private final class VariantStoreSpy: LibraryTranslationStoring {
    struct Upsert { let parentID: Int64; let target: TranslationTarget; let text: String }
    var variants: [DictationTranslationVariant]
    var upserts: [Upsert] = []
    var parentExists = true

    init(variants: [DictationTranslationVariant] = []) { self.variants = variants }

    func translationVariants(parentID: Int64) throws -> [DictationTranslationVariant] { variants }

    func upsertTranslation(parentID: Int64, target: TranslationTarget, text: String) throws {
        guard parentExists else { throw DatabaseError.translationParentMissing(parentID) }
        upserts.append(.init(parentID: parentID, target: target, text: text))
        let now = Date()
        if let index = variants.firstIndex(where: { $0.parentID == parentID && $0.target == target }) {
            variants[index].text = text
            variants[index].updatedAt = now
        } else {
            variants.append(.init(parentID: parentID, target: target, text: text, createdAt: now, updatedAt: now))
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
