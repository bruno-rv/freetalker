import Foundation

struct ScratchpadInsertionToken: Hashable, Sendable {
    let id: UUID
}

enum RecordingDestination: Equatable, Sendable {
    case external
    case scratchpad(ScratchpadInsertionToken)

    var requiresDurableJournal: Bool { true }

    var journalIdentifier: String {
        switch self {
        case .external: "external"
        case .scratchpad(let token): "scratchpad:\(token.id.uuidString)"
        }
    }
}

struct RecordingProcessingContext: Equatable, Sendable {
    let destination: RecordingDestination
    let spokenLanguage: String?
    let outputLanguage: OutputLanguage
    let template: Template
    let cloudSnapshot: CloudLLMSettingsSnapshot?
    /// The stop-time `VoiceCommandPolicy` for this dictation (PLAN.md PR A, item 2) — from the
    /// `VoiceCommandSnapshot` captured at `AppCoordinator.makeStopRequest`, enabled per toggle.
    /// Defaults to `.disabled` for the same reason `candidateLanguages` below defaults to `[]`:
    /// existing/test call sites that don't exercise voice commands keep compiling; every real
    /// production call site (`stopAndTranscribeToScratchpad`, `processDictation`'s convenience
    /// initializer) passes the actual snapshot-derived policy.
    var voiceCommandPolicy: VoiceCommandPolicy = .disabled
    /// The Dictation Language Set this dictation's local WhisperKit request is constrained to —
    /// the Recording-start snapshot (`AppCoordinator.recordingLanguageSnapshot`), not
    /// necessarily the live configured set. Defaults to `[]` so existing/test call sites that
    /// don't exercise the language-resolution path (most already construct this without caring)
    /// keep compiling; every real production call site passes the actual snapshot. See PLAN.md
    /// F5.3/F5.4.
    var candidateLanguages: [String] = []
    /// The effective vocabulary (manual + approved self-learning terms), snapshotted ONCE at stop
    /// time (`AppCoordinator.makeStopRequest`/`captureStopSettingsSnapshot`) and carried through
    /// to every consumer of this dictation's processing — STT biasing (`engine.transcribe`) and
    /// post-processing (`PostProcessingRequest.vocabulary`) alike — so the two can never disagree
    /// about which vocabulary applied to this dictation, even though the actual work can run long
    /// after a later `vocabularyText` edit or vocabulary decision changes what's "live". Mirrors
    /// `candidateLanguages`'/`cloudSnapshot`'s own snapshot-threading pattern (PLAN.md PR A, item
    /// 2 did the same for `voiceCommandPolicy`). Defaults to `[]` for the same
    /// existing/test-call-site-compiles reasoning as `candidateLanguages`; every real production
    /// call site passes the actual stop-time snapshot. See PLAN.md PR B, item 2d/4, Codex round 1
    /// finding 4.
    var vocabularySnapshot: [String] = []

    /// Re-validates `spokenLanguage` against `candidateLanguages` before it's handed to the
    /// engine as `forcedLanguage` — `resolveLanguage` already validates its inputs, so this is
    /// defense in depth against a stale/mismatched context rather than the primary check.
    var transcriptionLanguage: String? {
        guard let spokenLanguage, candidateLanguages.contains(spokenLanguage) else { return nil }
        return spokenLanguage
    }

    var recoverySafe: Self {
        Self(
            destination: destination, spokenLanguage: spokenLanguage,
            outputLanguage: outputLanguage, template: template, cloudSnapshot: nil,
            voiceCommandPolicy: voiceCommandPolicy,
            candidateLanguages: candidateLanguages,
            vocabularySnapshot: vocabularySnapshot
        )
    }
}

struct RecordingProcessingResult {
    let rawTranscript: String
    let finalOutput: String
    let sourceLanguage: SourceLanguage
    let requestedOutputLanguage: OutputLanguage
    let templateName: String
    let engineName: String
    let posted: Bool
    let fallbackReason: AppCoordinator.PostProcessingFallbackReason?
}

struct OutputTranslationFailure: Error, LocalizedError {
    let id: UUID
    let source: String
    let context: RecordingProcessingContext
    let engineName: String
    let underlyingError: Error

    init(
        id: UUID = UUID(), source: String, context: RecordingProcessingContext,
        engineName: String,
        underlyingError: Error
    ) {
        self.id = id
        self.source = source
        self.context = context.recoverySafe
        self.engineName = engineName
        self.underlyingError = underlyingError
    }

    var errorDescription: String? { "Translation failed" }
}

enum RecordingDestinationEvent: Equatable {
    case preview(String?)
    case completion(String)
    case cancellation
    case failure(String)
}

@MainActor
protocol ScratchpadRecordingRouting: AnyObject {
    func updatePreview(_ text: String?, for token: ScratchpadInsertionToken)
    func completeRecording(_ text: String, for token: ScratchpadInsertionToken) -> Bool
    func cancelRecording(for token: ScratchpadInsertionToken)
    func failRecording(_ message: String, for token: ScratchpadInsertionToken)
    func completeTranslationRecovery(_ text: String, for token: ScratchpadInsertionToken) -> Bool
}

extension ScratchpadRecordingRouting {
    func completeTranslationRecovery(_ text: String, for token: ScratchpadInsertionToken) -> Bool {
        completeRecording(text, for: token)
    }
}

@MainActor
final class RecordingDestinationLifecycle {
    struct PendingRecording: Equatable {
        let token: ScratchpadInsertionToken
        let text: String
    }

    private(set) var currentDestination: RecordingDestination?
    private var recoveries: [ScratchpadInsertionToken: String] = [:]
    private var recoveryOrder: [ScratchpadInsertionToken] = []
    private var pendingFailures: [String] = []
    weak var router: (any ScratchpadRecordingRouting)?

    init(router: (any ScratchpadRecordingRouting)? = nil) { self.router = router }

    func install(_ destination: RecordingDestination) { currentDestination = destination }
    func take() -> RecordingDestination {
        defer { currentDestination = nil }
        return currentDestination ?? .external
    }

    func begin(_ destination: RecordingDestination, start: () -> Bool, failureMessage: () -> String) -> Bool {
        guard start() else {
            failStart(destination, message: failureMessage())
            return false
        }
        install(destination)
        return true
    }

    func failStart(_ destination: RecordingDestination, message: String) {
        currentDestination = nil
        if case .scratchpad(let token) = destination {
            if let router { router.failRecording(message, for: token) }
            else { pendingFailures.append(message) }
        }
    }

    func cancel(stop: () -> Void) {
        let destination = take()
        stop()
        if case .scratchpad(let token) = destination {
            router?.cancelRecording(for: token)
            clearPending(for: token)
        }
    }

    func complete(
        _ text: String,
        destination: RecordingDestination,
        external: () throws -> Void
    ) throws -> Bool {
        switch destination {
        case .external:
            try external()
            return true
        case .scratchpad(let token):
            let accepted = router?.completeRecording(text, for: token) ?? false
            if accepted { clearPending(for: token) }
            else { storePending(text, for: token) }
            return accepted
        }
    }

    func runAsync<Value>(
        destination: RecordingDestination,
        process: () async throws -> Value,
        text: (Value) -> String,
        external: (Value) throws -> Void
    ) async throws -> (value: Value, accepted: Bool) {
        do {
            let value = try await process()
            let accepted = try complete(text(value), destination: destination) {
                try external(value)
            }
            return (value, accepted)
        } catch {
            if case .scratchpad(let token) = destination {
                if error is CancellationError || Task.isCancelled {
                    router?.cancelRecording(for: token)
                    clearPending(for: token)
                } else {
                    if let router { router.failRecording(error.localizedDescription, for: token) }
                    else { pendingFailures.append(error.localizedDescription) }
                }
            }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func pending(for token: ScratchpadInsertionToken) -> String? { recoveries[token] }
    func pendingRecordings() -> [PendingRecording] {
        recoveryOrder.compactMap { token in
            recoveries[token].map { PendingRecording(token: token, text: $0) }
        }
    }
    func consumePending(for token: ScratchpadInsertionToken) -> String? {
        defer { recoveryOrder.removeAll { $0 == token } }
        return recoveries.removeValue(forKey: token)
    }
    func storePending(_ text: String, for token: ScratchpadInsertionToken) {
        guard recoveries[token] == nil else { return }
        recoveryOrder.append(token)
        recoveries[token] = text
    }
    func clearPending(for token: ScratchpadInsertionToken) {
        recoveries.removeValue(forKey: token)
        recoveryOrder.removeAll { $0 == token }
    }
    func consumePendingFailure() -> String? {
        guard !pendingFailures.isEmpty else { return nil }
        return pendingFailures.removeFirst()
    }
    func storePendingFailure(_ message: String) { pendingFailures.append(message) }
}
