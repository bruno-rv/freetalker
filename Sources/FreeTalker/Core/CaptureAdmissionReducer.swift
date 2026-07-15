import Foundation

enum CaptureAdmissionState: Equatable {
    case idle
    case preparing(destination: String, stopRequested: Bool, cancelRequested: Bool)
    case recording(captureID: UUID)
    case cancelling(captureID: UUID)
}

enum CaptureAdmissionEvent: Equatable {
    case begin(destination: String)
    case prepared(captureID: UUID)
    case preparationFailed(String)
    case stopRequested
    case cancelRequested
    case cleanupFinished
}

enum CaptureAdmissionAction: Equatable {
    case none
    case start(UUID)
    case startAndStop(UUID)
    case finish(UUID)
    case cancel(UUID)
    case fail(String)
}

struct CaptureAdmissionReducer {
    private(set) var state: CaptureAdmissionState = .idle

    mutating func reduce(_ event: CaptureAdmissionEvent) -> CaptureAdmissionAction {
        switch (state, event) {
        case (.idle, .begin(let destination)):
            state = .preparing(
                destination: destination, stopRequested: false, cancelRequested: false
            )
            return .none

        case (.preparing(let destination, _, let cancel), .stopRequested):
            state = .preparing(
                destination: destination, stopRequested: true, cancelRequested: cancel
            )
            return .none

        case (.preparing(let destination, let stop, _), .cancelRequested):
            state = .preparing(
                destination: destination, stopRequested: stop, cancelRequested: true
            )
            return .none

        case (.preparing(_, let stop, let cancel), .prepared(let captureID)):
            if cancel {
                state = .cancelling(captureID: captureID)
                return .cancel(captureID)
            }
            state = .recording(captureID: captureID)
            return stop ? .startAndStop(captureID) : .start(captureID)

        case (.preparing, .preparationFailed(let message)),
             (.recording, .preparationFailed(let message)):
            state = .idle
            return .fail(message)

        case (.recording(let captureID), .stopRequested):
            return .finish(captureID)

        case (.recording(let captureID), .cancelRequested):
            state = .cancelling(captureID: captureID)
            return .cancel(captureID)

        case (.cancelling, .cleanupFinished):
            state = .idle
            return .none

        default:
            return .none
        }
    }
}
