import Foundation

enum RecoveryHealth: Equatable, Sendable {
    case initializing
    case healthy
    case degraded(String)
    case unavailable(String)

    func allowsCapture(
        requiresDurableJournal: Bool,
        admissionStorageHealthy: Bool
    ) -> Bool {
        guard requiresDurableJournal else { return true }
        switch self {
        case .healthy:
            return admissionStorageHealthy
        case .degraded:
            return admissionStorageHealthy
        case .initializing, .unavailable:
            return false
        }
    }

    static func resolve(
        storeFailure: String?,
        itemFailures: [String],
        ownedFailure: String? = nil
    ) -> RecoveryHealth {
        if let storeFailure { return .unavailable(storeFailure) }
        if let ownedFailure { return .degraded(ownedFailure) }
        if let itemFailure = itemFailures.first { return .degraded(itemFailure) }
        return .healthy
    }

    var message: String? {
        switch self {
        case .degraded(let message), .unavailable(let message): message
        case .initializing: "Recovery setup is initializing."
        case .healthy: nil
        }
    }

    func beginRetry() -> RecoveryHealth { .initializing }
}

struct RecoveryHealthWarning: Equatable, Sendable {
    static let actionTitle = "Retry Recovery Setup"

    let message: String
    let actionTitle: String

    init?(health: RecoveryHealth) {
        let message: String
        switch health {
        case .degraded(let detail), .unavailable(let detail): message = detail
        case .initializing, .healthy: return nil
        }
        self.message = message
        actionTitle = Self.actionTitle
    }
}

struct SilentCapturePresentation: Equatable, Sendable {
    static let message = "No microphone signal was captured."

    let id: UUID
    let capturedAt: Date
    let message: String
    let isRetryable = false

    init?(session: CaptureSession) {
        guard session.state == .silent, session.assetKind == .silent else { return nil }
        id = session.id
        capturedAt = session.capturedAt
        message = session.failureMessage ?? Self.message
    }
}
