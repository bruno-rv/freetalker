import AppKit
import Combine
import Foundation

struct LibraryInsertionDestination {
    let bundleIdentifier: String
    let target: InsertionTarget
}

@MainActor
final class LibraryInsertionDestinationStore: ObservableObject {
    static let shared = LibraryInsertionDestinationStore()
    @Published private(set) var destination: LibraryInsertionDestination?

    func capture(
        frontmostApplication: NSRunningApplication? = NSWorkspace.shared.frontmostApplication,
        snapshotTarget: (NSRunningApplication?) -> InsertionTarget? = Insertion.snapshotTarget
    ) {
        let ownBundleID = Bundle.main.bundleIdentifier
        guard let app = frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != ownBundleID,
              let target = snapshotTarget(app) else {
            destination = nil
            return
        }
        destination = .init(bundleIdentifier: bundleID, target: target)
    }
}

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
    enum Selection: Hashable { case original, variant(TranslationTarget) }
    typealias Snapshot = @MainActor () -> CloudLLMSettingsSnapshot
    typealias Copy = @MainActor (String) throws -> Void
    typealias Destination = @MainActor () -> LibraryInsertionDestination?
    typealias TargetedInsert = @MainActor (String, InsertionTarget) -> Bool

    @Published private(set) var variants: [DictationTranslationVariant] = []
    @Published private(set) var selection: Selection = .original
    @Published private(set) var isTranslating = false
    @Published private(set) var pendingReplacementTarget: TranslationTarget?
    @Published private(set) var errorMessage: String?
    @Published private(set) var insertionFailureMessage: String?
    @Published private(set) var availability: CloudFeatureAvailability

    var canRetry: Bool { lastRequestedTarget != nil && errorMessage != nil }
    var canInsert: Bool { destination() != nil }

    private struct PendingReplacement {
        let entry: Dictation
        let target: TranslationTarget
        let version: Date
        let translatedText: String?
    }

    private let translator: any Translating
    private let store: any LibraryTranslationStoring
    private let snapshot: Snapshot
    private let copy: Copy
    private let destination: Destination
    private let targetedInsert: TargetedInsert
    private var subscriptions: Set<AnyCancellable> = []
    private var generation = 0
    private var requestTask: Task<Void, Never>?
    private var pendingReplacement: PendingReplacement?
    private var lastRequestedTarget: TranslationTarget?
    private var selectedEntryID: Int64?

    init(
        translator: any Translating = TranslationService(),
        store: any LibraryTranslationStoring = LibraryStore.shared,
        snapshot: @escaping Snapshot = { AppSettings.shared.cloudLLMSnapshot },
        copy: @escaping Copy = LibraryTranslationController.copyToPasteboard,
        destination: @escaping Destination = { LibraryInsertionDestinationStore.shared.destination },
        targetedInsert: @escaping TargetedInsert = { Insertion.insert($0, target: $1) },
        cloudConfigurationUpdates: AnyPublisher<Void, Never>? = nil,
        cloudCredentialUpdates: AnyPublisher<Void, Never>? = nil
    ) {
        self.translator = translator
        self.store = store
        self.snapshot = snapshot
        self.copy = copy
        self.destination = destination
        self.targetedInsert = targetedInsert
        let initial = snapshot()
        availability = .make(eligibility: initial.eligibility, provider: initial.provider)

        let configuration = cloudConfigurationUpdates ?? Publishers.Merge3(
            AppSettings.shared.$llmProvider.map { _ in () },
            AppSettings.shared.$cloudLLMBaseURL.map { _ in () },
            AppSettings.shared.$cloudLLMModel.map { _ in () }
        ).dropFirst(3).eraseToAnyPublisher()
        let credentials = cloudCredentialUpdates ?? NotificationCenter.default.publisher(
            for: .cloudLLMCredentialsDidChange
        ).map { _ in () }.eraseToAnyPublisher()
        Publishers.Merge(configuration, credentials)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshAvailability() }
            .store(in: &subscriptions)
    }

    func selectEntry(id: Int64) {
        guard selectedEntryID != id else { return }
        cancel()
        selectedEntryID = id
        variants = []
        selection = .original
        pendingReplacement = nil
        pendingReplacementTarget = nil
        errorMessage = nil
        insertionFailureMessage = nil
        lastRequestedTarget = nil
        loadVariants(parentID: id)
    }

    func loadVariants(parentID: Int64) {
        do { variants = try store.translationVariants(parentID: parentID) }
        catch { errorMessage = error.localizedDescription }
    }

    func translate(entry: Dictation, to target: TranslationTarget) {
        guard selectedEntryID == entry.id else { return }
        errorMessage = nil
        lastRequestedTarget = target
        if let existing = variants.first(where: { $0.parentID == entry.id && $0.target == target }) {
            pendingReplacement = .init(entry: entry, target: target, version: existing.updatedAt, translatedText: nil)
            pendingReplacementTarget = target
            return
        }
        beginTranslation(entry: entry, target: target, expected: .absent)
    }

    func confirmReplacement() {
        guard let pending = pendingReplacement, selectedEntryID == pending.entry.id else { return }
        pendingReplacement = nil
        pendingReplacementTarget = nil
        if let text = pending.translatedText {
            persist(text, entry: pending.entry, target: pending.target, expected: .version(pending.version), generation: generation)
        } else {
            beginTranslation(entry: pending.entry, target: pending.target, expected: .version(pending.version))
        }
    }

    func dismissReplacement() { pendingReplacement = nil; pendingReplacementTarget = nil }
    func retry(entry: Dictation) { if let target = lastRequestedTarget { translate(entry: entry, to: target) } }
    func dismissError() { errorMessage = nil }
    func dismissInsertionFailure() { insertionFailureMessage = nil }

    func cancel() {
        generation += 1
        requestTask?.cancel()
        requestTask = nil
        isTranslating = false
    }

    func select(_ selection: Selection) { self.selection = selection }

    func displayedText(for entry: Dictation) -> String {
        guard selectedEntryID == entry.id else { return Self.canonicalSource(for: entry) }
        switch selection {
        case .original: return Self.canonicalSource(for: entry)
        case .variant(let target): return variants.first(where: { $0.target == target })?.text ?? Self.canonicalSource(for: entry)
        }
    }

    func copyDisplayedText(for entry: Dictation) throws { try copy(displayedText(for: entry)) }

    @discardableResult
    func insertDisplayedText(for entry: Dictation) -> Bool {
        guard selectedEntryID == entry.id else { return false }
        let text = displayedText(for: entry)
        guard let destination = destination() else {
            try? copy(text)
            insertionFailureMessage = "No safe insertion target was captured. The text was copied; return to the destination and paste it manually."
            return false
        }
        let inserted = targetedInsert(text, destination.target)
        insertionFailureMessage = inserted ? nil : "The original insertion target changed. Choose Copy, return to the destination, and paste it manually."
        return inserted
    }

    func waitForCurrentRequest() async { await requestTask?.value }

    private func beginTranslation(entry: Dictation, target: TranslationTarget, expected: TranslationVariantExpectation) {
        generation += 1
        let requestGeneration = generation
        requestTask?.cancel()
        let captured = snapshot()
        availability = .make(eligibility: captured.eligibility, provider: captured.provider)
        guard availability.enabled else { errorMessage = availability.accessibilityHelp; return }
        isTranslating = true
        requestTask = Task { [translator] in
            do {
                let text = try await translator.process(
                    source: Self.canonicalSource(for: entry), template: Self.translationTemplate,
                    policy: .translate(to: target), snapshot: captured
                )
                guard requestGeneration == generation, selectedEntryID == entry.id, !Task.isCancelled else { return }
                persist(text, entry: entry, target: target, expected: expected, generation: requestGeneration)
            } catch {
                guard requestGeneration == generation, selectedEntryID == entry.id, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isTranslating = false
            }
        }
    }

    private func persist(_ text: String, entry: Dictation, target: TranslationTarget, expected: TranslationVariantExpectation, generation requestGeneration: Int) {
        do {
            let result = try store.conditionalUpsertTranslation(parentID: entry.id, target: target, text: text, expected: expected)
            guard requestGeneration == generation, selectedEntryID == entry.id else { return }
            switch result {
            case .committed(let variant):
                variants.removeAll { $0.parentID == variant.parentID && $0.target == variant.target }
                variants.append(variant)
                selection = .variant(target)
            case .replacementConfirmationRequired(let current):
                variants.removeAll { $0.parentID == current.parentID && $0.target == current.target }
                variants.append(current)
                pendingReplacement = .init(entry: entry, target: target, version: current.updatedAt, translatedText: text)
                pendingReplacementTarget = target
            }
            isTranslating = false
        } catch {
            guard requestGeneration == generation, selectedEntryID == entry.id else { return }
            errorMessage = error.localizedDescription
            isTranslating = false
        }
    }

    private func refreshAvailability() {
        let current = snapshot()
        availability = .make(eligibility: current.eligibility, provider: current.provider)
    }

    private static func canonicalSource(for entry: Dictation) -> String {
        entry.refined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? entry.transcript : entry.refined
    }
    private static let translationTemplate = Template(id: "library-translation", name: "Library Translation", prompt: "Preserve the source meaning, structure, and tone. Output only the translated text.")
    private static func copyToPasteboard(_ text: String) throws {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { throw CocoaError(.fileWriteUnknown) }
    }
}
