import Foundation

enum CaptureAdmissionState: Equatable {
    case idle
    case preparing(
        captureID: UUID, destination: String,
        stopRequested: Bool, cancelRequested: Bool
    )
    case recording(captureID: UUID)
    case finalizing(captureID: UUID)
    case cancelling(captureID: UUID)
    case cleanupFailed(captureID: UUID, message: String)

    var captureID: UUID? {
        switch self {
        case .idle: nil
        case .preparing(let id, _, _, _), .recording(let id), .finalizing(let id),
             .cancelling(let id), .cleanupFailed(let id, _): id
        }
    }

    var isActive: Bool { self != .idle }
}

enum CaptureAdmissionEvent: Equatable {
    case begin(captureID: UUID, destination: String)
    case prepared(captureID: UUID)
    case preparationFailed(captureID: UUID, message: String)
    case stopRequested
    case cancelRequested
    case finalizationFinished(captureID: UUID)
    case failureHandlingStarted(captureID: UUID)
    case failureHandled(captureID: UUID)
    case cleanupFailed(captureID: UUID, message: String)
    case cleanupFinished(captureID: UUID)
}

enum CaptureAdmissionAction: Equatable {
    case none
    case start(UUID)
    case startAndStop(UUID)
    case finish(UUID)
    case cancel(UUID)
    case preserveFailure(UUID)
    case fail(String)
}

struct CaptureAdmissionReducer {
    private(set) var state: CaptureAdmissionState = .idle

    mutating func reduce(_ event: CaptureAdmissionEvent) -> CaptureAdmissionAction {
        switch (state, event) {
        case (.idle, .begin(let captureID, let destination)):
            state = .preparing(
                captureID: captureID, destination: destination,
                stopRequested: false, cancelRequested: false
            )
            return .none

        case (.preparing(let id, let destination, _, let cancel), .stopRequested):
            state = .preparing(
                captureID: id, destination: destination,
                stopRequested: true, cancelRequested: cancel
            )
            return .none

        case (.preparing(let id, let destination, let stop, _), .cancelRequested):
            state = .preparing(
                captureID: id, destination: destination,
                stopRequested: stop, cancelRequested: true
            )
            return .none

        case (.preparing(let expected, _, let stop, let cancel), .prepared(let captureID))
            where expected == captureID:
            if cancel {
                state = .cancelling(captureID: captureID)
                return .cancel(captureID)
            }
            state = .recording(captureID: captureID)
            return stop ? .startAndStop(captureID) : .start(captureID)

        case (.preparing(let expected, _, _, _), .preparationFailed(let captureID, let message))
            where expected == captureID,
             (.recording(let expected), .preparationFailed(let captureID, let message))
            where expected == captureID:
            state = .idle
            return .fail(message)

        case (.recording(let captureID), .stopRequested):
            state = .finalizing(captureID: captureID)
            return .finish(captureID)

        case (.recording(let captureID), .cancelRequested),
             (.finalizing(let captureID), .cancelRequested):
            state = .cancelling(captureID: captureID)
            return .cancel(captureID)

        case (.recording(let expected), .failureHandlingStarted(let captureID))
            where expected == captureID,
             (.finalizing(let expected), .failureHandlingStarted(let captureID))
            where expected == captureID:
            state = .finalizing(captureID: captureID)
            return .preserveFailure(captureID)

        case (.finalizing(let expected), .finalizationFinished(let captureID))
            where expected == captureID,
             (.finalizing(let expected), .failureHandled(let captureID))
            where expected == captureID:
            state = .idle
            return .none

        case (.cleanupFailed(let expected, _), .failureHandled(let captureID))
            where expected == captureID:
            state = .idle
            return .none

        case (.cleanupFailed(let captureID, _), .cancelRequested):
            state = .cancelling(captureID: captureID)
            return .cancel(captureID)

        case (.cancelling(let expected), .cleanupFailed(let captureID, let message))
            where expected == captureID,
             (.finalizing(let expected), .cleanupFailed(let captureID, let message))
            where expected == captureID,
             (.cleanupFailed(let expected, _), .cleanupFailed(let captureID, let message))
            where expected == captureID:
            state = .cleanupFailed(captureID: captureID, message: message)
            return .fail(message)

        case (.cancelling(let expected), .cleanupFinished(let captureID))
            where expected == captureID,
             (.cleanupFailed(let expected, _), .cleanupFinished(let captureID))
            where expected == captureID:
            state = .idle
            return .none

        default:
            return .none
        }
    }
}

struct CaptureCleanupRetryGate {
    private var active: (captureID: UUID, generation: UUID)?

    mutating func begin(captureID: UUID) -> UUID? {
        guard active == nil else { return nil }
        let generation = UUID()
        active = (captureID, generation)
        return generation
    }

    mutating func finish(captureID: UUID, generation: UUID) -> Bool {
        guard active?.captureID == captureID, active?.generation == generation else {
            return false
        }
        active = nil
        return true
    }

    func isInFlight(captureID: UUID) -> Bool { active?.captureID == captureID }
}

enum CaptureCanonicalAudioLoader {
    static func load(
        _ operation: @escaping @Sendable () throws -> [Float]
    ) async throws -> [Float] {
        try await Task.detached(operation: operation).value
    }
}
