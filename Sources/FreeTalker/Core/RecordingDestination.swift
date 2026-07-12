import Foundation

struct ScratchpadInsertionToken: Hashable, Sendable {
    let id: UUID
}

enum RecordingDestination: Equatable, Sendable {
    case external
    case scratchpad(ScratchpadInsertionToken)
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
                if error is CancellationError {
                    router?.cancelRecording(for: token)
                    clearPending(for: token)
                } else {
                    if let router { router.failRecording(error.localizedDescription, for: token) }
                    else { pendingFailures.append(error.localizedDescription) }
                }
            }
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
