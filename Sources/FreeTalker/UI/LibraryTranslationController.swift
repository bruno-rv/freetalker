import AppKit
import Foundation

struct LibraryTranslationPresentation: Equatable {
    static let privacyDisclosure = "Translation sends this text to the API endpoint configured under Cloud post-processing."

    let availability: CloudFeatureAvailability

    var isEnabled: Bool { availability.enabled }
    var tooltip: String? { availability.tooltip }
    var accessibilityHelp: String? { availability.accessibilityHelp }
    var privacyDisclosure: String { Self.privacyDisclosure }
    var targets: [TranslationTarget] { TranslationTarget.allCases }
}

@MainActor
final class LibraryTranslationController: ObservableObject {
    enum Selection: Hashable {
        case original
        case variant(TranslationTarget)
    }

    typealias Snapshot = @MainActor () -> CloudLLMSettingsSnapshot
    typealias Copy = @MainActor (String) throws -> Void
    typealias Insert = @MainActor (String) -> Void

    @Published private(set) var variants: [DictationTranslationVariant] = []
    @Published private(set) var selection: Selection = .original
    @Published private(set) var isTranslating = false
    @Published private(set) var pendingReplacementTarget: TranslationTarget?
    @Published private(set) var errorMessage: String?

    var canRetry: Bool { lastRequestedTarget != nil && errorMessage != nil }

    private let translator: any Translating
    private let store: any LibraryTranslationStoring
    private let snapshot: Snapshot
    private let copy: Copy
    private let insert: Insert
    private var generation = 0
    private var requestTask: Task<Void, Never>?
    private var pendingReplacement: (entry: Dictation, target: TranslationTarget)?
    private var lastRequestedTarget: TranslationTarget?

    init(
        translator: any Translating = TranslationService(),
        store: any LibraryTranslationStoring = LibraryStore.shared,
        snapshot: @escaping Snapshot = { AppSettings.shared.cloudLLMSnapshot },
        copy: @escaping Copy = LibraryTranslationController.copyToPasteboard,
        insert: @escaping Insert = { Insertion.insert($0) }
    ) {
        self.translator = translator
        self.store = store
        self.snapshot = snapshot
        self.copy = copy
        self.insert = insert
    }

    func loadVariants(parentID: Int64) {
        do {
            variants = try store.translationVariants(parentID: parentID)
            if case .variant(let target) = selection,
               !variants.contains(where: { $0.target == target }) {
                selection = .original
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func translate(entry: Dictation, to target: TranslationTarget) {
        errorMessage = nil
        lastRequestedTarget = target
        if variants.contains(where: { $0.parentID == entry.id && $0.target == target }) {
            pendingReplacement = (entry, target)
            pendingReplacementTarget = target
            return
        }
        beginTranslation(entry: entry, target: target)
    }

    func confirmReplacement() {
        guard let pendingReplacement else { return }
        self.pendingReplacement = nil
        pendingReplacementTarget = nil
        beginTranslation(entry: pendingReplacement.entry, target: pendingReplacement.target)
    }

    func dismissReplacement() {
        pendingReplacement = nil
        pendingReplacementTarget = nil
    }

    func retry(entry: Dictation) {
        guard let lastRequestedTarget else { return }
        beginTranslation(entry: entry, target: lastRequestedTarget)
    }

    func dismissError() {
        errorMessage = nil
    }

    func cancel() {
        generation += 1
        requestTask?.cancel()
        requestTask = nil
        isTranslating = false
    }

    func select(_ selection: Selection) {
        self.selection = selection
    }

    func displayedText(for entry: Dictation) -> String {
        switch selection {
        case .original:
            return Self.canonicalSource(for: entry)
        case .variant(let target):
            return variants.first(where: { $0.target == target })?.text
                ?? Self.canonicalSource(for: entry)
        }
    }

    func copyDisplayedText(for entry: Dictation) throws {
        try copy(displayedText(for: entry))
    }

    func insertDisplayedText(for entry: Dictation) {
        insert(displayedText(for: entry))
    }

    func waitForCurrentRequest() async {
        await requestTask?.value
    }

    private func beginTranslation(entry: Dictation, target: TranslationTarget) {
        generation += 1
        let requestGeneration = generation
        requestTask?.cancel()
        let capturedSnapshot = snapshot()
        let availability = CloudFeatureAvailability.make(
            eligibility: capturedSnapshot.eligibility,
            provider: capturedSnapshot.provider
        )
        guard availability.enabled else {
            isTranslating = false
            errorMessage = availability.accessibilityHelp
            return
        }

        let source = Self.canonicalSource(for: entry)
        isTranslating = true
        requestTask = Task { [translator, store] in
            do {
                let translated = try await translator.process(
                    source: source,
                    template: Self.translationTemplate,
                    policy: .translate(to: target),
                    snapshot: capturedSnapshot
                )
                guard requestGeneration == generation, !Task.isCancelled else { return }
                try store.upsertTranslation(parentID: entry.id, target: target, text: translated)
                let refreshed = try store.translationVariants(parentID: entry.id)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                variants = refreshed
                selection = .variant(target)
                isTranslating = false
            } catch is CancellationError {
                guard requestGeneration == generation else { return }
                isTranslating = false
            } catch {
                guard requestGeneration == generation, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isTranslating = false
            }
        }
    }

    private static func canonicalSource(for entry: Dictation) -> String {
        entry.refined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? entry.transcript
            : entry.refined
    }

    private static let translationTemplate = Template(
        id: "library-translation",
        name: "Library Translation",
        prompt: "Preserve the source meaning, structure, and tone. Output only the translated text."
    )

    private static func copyToPasteboard(_ text: String) throws {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
