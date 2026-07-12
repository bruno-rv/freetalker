import Foundation

@MainActor
protocol TranslationRecoveryPresentationRouting: AnyObject {
    func translationRecoveryPresentationDidChange()
}

struct PendingTranslationRecovery {
    let failureID: UUID
    let sourceTranscript: String
    let sourceLanguage: String?
    let outputLanguage: TranslationTarget
    let template: Template
    let engineName: String
    let destination: RecordingDestination
    let generation: UUID
    let capturedExternalTarget: InsertionTarget?
    var recoverableText: String

    init(
        failure: OutputTranslationFailure,
        generation: UUID = UUID(),
        capturedExternalTarget: InsertionTarget? = nil,
        recoverableText: String? = nil
    ) {
        failureID = failure.id
        sourceTranscript = failure.source
        sourceLanguage = failure.context.spokenLanguage
        guard case .translate(let outputLanguage) = failure.context.outputLanguage.processingPolicy else {
            preconditionFailure("Translation recovery requires a translated output language")
        }
        self.outputLanguage = outputLanguage
        template = failure.context.template
        engineName = failure.engineName
        destination = failure.context.destination
        self.generation = generation
        self.capturedExternalTarget = capturedExternalTarget
        self.recoverableText = recoverableText ?? failure.source
    }

    private init(replacingGenerationOf recovery: Self, with generation: UUID) {
        failureID = recovery.failureID
        sourceTranscript = recovery.sourceTranscript
        sourceLanguage = recovery.sourceLanguage
        outputLanguage = recovery.outputLanguage
        template = recovery.template
        engineName = recovery.engineName
        destination = recovery.destination
        self.generation = generation
        capturedExternalTarget = recovery.capturedExternalTarget
        recoverableText = recovery.recoverableText
    }

    func replacingGeneration(with generation: UUID = UUID()) -> Self {
        Self(replacingGenerationOf: self, with: generation)
    }
}

struct TranslationRecoveryHistoryRecord: Equatable {
    let rawTranscript: String
    let finalOutput: String
    let sourceLanguage: SourceLanguage
    let requestedOutputLanguage: OutputLanguage
    let templateName: String
    let engineName: String
}

struct TranslationRecoveryPresentation: Equatable {
    static let retryTitle = "Retry translation"
    static let insertSourceTitle = "Insert source text"

    let message: String
    let retryTitle: String
    let insertSourceTitle: String
    let recoverableText: String
    let isRetrying: Bool
    let actionsEnabled: Bool
    let errorText: String?

    static func sourceActionTitle(outputLanguage: OutputLanguage) -> String {
        if case .translate = outputLanguage.processingPolicy { return "Use source text" }
        return "Raw"
    }
}

@MainActor
final class PendingTranslationRecoveryController {
    typealias Snapshot = () -> CloudLLMSettingsSnapshot
    typealias Translate = (
        _ source: String,
        _ template: Template,
        _ policy: OutputProcessingPolicy,
        _ snapshot: CloudLLMSettingsSnapshot
    ) async throws -> String
    typealias Deliver = (
        _ text: String,
        _ destination: RecordingDestination,
        _ externalTarget: InsertionTarget?
    ) -> Bool
    typealias RecordResolved = (TranslationRecoveryHistoryRecord) throws -> Void

    private let snapshot: Snapshot
    private let translate: Translate
    private let deliver: Deliver
    private let recordResolved: RecordResolved
    private let onHistoryFailure: (String) -> Void
    private let onChange: () -> Void
    private var recoveries: [PendingTranslationRecovery] = []
    private var inFlightIDs: Set<UUID> = []
    private var errors: [UUID: String] = [:]

    init(
        snapshot: @escaping Snapshot,
        translate: @escaping Translate,
        deliver: @escaping Deliver,
        recordResolved: @escaping RecordResolved = { _ in },
        onHistoryFailure: @escaping (String) -> Void = { _ in },
        onChange: @escaping () -> Void = {}
    ) {
        self.snapshot = snapshot
        self.translate = translate
        self.deliver = deliver
        self.recordResolved = recordResolved
        self.onHistoryFailure = onHistoryFailure
        self.onChange = onChange
    }

    var pendingRecoveries: [PendingTranslationRecovery] { recoveries }

    func enqueue(_ failure: OutputTranslationFailure, externalTarget: InsertionTarget? = nil) {
        guard !recoveries.contains(where: { $0.failureID == failure.id }) else { return }
        recoveries.append(PendingTranslationRecovery(failure: failure, capturedExternalTarget: externalTarget))
        onChange()
    }

    func presentation(for id: UUID) -> TranslationRecoveryPresentation? {
        recoveries.first(where: { $0.failureID == id }).map {
            TranslationRecoveryPresentation(
                message: "Translation failed",
                retryTitle: Self.retryTitle,
                insertSourceTitle: TranslationRecoveryPresentation.insertSourceTitle,
                recoverableText: $0.recoverableText,
                isRetrying: inFlightIDs.contains(id),
                actionsEnabled: !inFlightIDs.contains(id),
                errorText: errors[id]
            )
        }
    }

    var nextPresentation: TranslationRecoveryPresentation? {
        recoveries.first.flatMap { presentation(for: $0.failureID) }
    }

    var nextID: UUID? { recoveries.first?.failureID }

    func retryTranslation(id: UUID) async {
        guard let index = recoveries.firstIndex(where: { $0.failureID == id }),
              !inFlightIDs.contains(id) else { return }
        let eligibleSnapshot = snapshot()
        guard eligibleSnapshot.eligibility.isEligible else {
            errors[id] = "Translation unavailable. Check cloud settings."
            onChange()
            return
        }
        let attempt = recoveries[index].replacingGeneration()
        recoveries[index] = attempt
        errors[id] = nil
        inFlightIDs.insert(id)
        onChange()
        defer {
            inFlightIDs.remove(id)
            onChange()
        }

        do {
            let output = try await translate(
                attempt.sourceTranscript,
                attempt.template,
                .translate(to: attempt.outputLanguage),
                eligibleSnapshot
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            guard !output.isEmpty,
                  let current = recoveries.first(where: { $0.failureID == id }),
                  current.generation == attempt.generation else { return }
            if deliver(output, attempt.destination, attempt.capturedExternalTarget) {
                remove(id: id, generation: attempt.generation)
                recordHistoryIfNeeded(attempt, finalOutput: output)
            } else {
                retain(output, id: id, generation: attempt.generation)
                errors[id] = "The original destination changed. Copy the preserved text or try again."
            }
        } catch is CancellationError {
            errors[id] = "Translation cancelled. Try again."
            return
        } catch {
            errors[id] = "Translation failed. Try again."
            return
        }
    }

    func insertSourceText(id: UUID) {
        guard !inFlightIDs.contains(id),
              let recovery = recoveries.first(where: { $0.failureID == id }) else { return }
        invalidateAttempt(id: id)
        if deliver(recovery.sourceTranscript, recovery.destination, recovery.capturedExternalTarget) {
            remove(id: id)
            recordHistoryIfNeeded(recovery, finalOutput: recovery.sourceTranscript)
        } else {
            retain(recovery.sourceTranscript, id: id)
            errors[id] = "The original destination changed. Copy the preserved text or try again."
        }
        onChange()
    }

    func invalidateAttempt(id: UUID) {
        guard let index = recoveries.firstIndex(where: { $0.failureID == id }) else { return }
        recoveries[index] = recoveries[index].replacingGeneration()
        inFlightIDs.remove(id)
        onChange()
    }

    func discard(id: UUID) {
        inFlightIDs.remove(id)
        remove(id: id)
        onChange()
    }

    private func remove(id: UUID, generation: UUID? = nil) {
        recoveries.removeAll {
            $0.failureID == id && (generation == nil || $0.generation == generation)
        }
        if !recoveries.contains(where: { $0.failureID == id }) { errors[id] = nil }
    }

    private func retain(_ text: String, id: UUID, generation: UUID? = nil) {
        guard let index = recoveries.firstIndex(where: {
            $0.failureID == id && (generation == nil || $0.generation == generation)
        }) else { return }
        recoveries[index].recoverableText = text
    }

    private func recordHistoryIfNeeded(_ recovery: PendingTranslationRecovery, finalOutput: String) {
        guard recovery.destination == .external else { return }
        do {
            try recordResolved(.init(
                rawTranscript: recovery.sourceTranscript,
                finalOutput: finalOutput,
                sourceLanguage: SourceLanguage(recovery.sourceLanguage ?? ""),
                requestedOutputLanguage: OutputLanguage(rawValue: recovery.outputLanguage.rawValue) ?? .sameAsSpoken,
                templateName: recovery.template.name,
                engineName: recovery.engineName
            ))
        } catch {
            onHistoryFailure("Library save failed")
        }
    }

    private static let retryTitle = TranslationRecoveryPresentation.retryTitle
}
