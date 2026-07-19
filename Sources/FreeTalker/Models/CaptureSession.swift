import Foundation

enum CaptureSessionState: String, Codable, Sendable {
    case capturing, staged, processing
    case libraryCommitted = "library_committed"
    case silent, damaged, cancelling
}

enum RecoveryAssetKind: String, Codable, Sendable {
    case audio, silent, damaged, quarantined
}

struct CaptureSession: Sendable, Equatable, Identifiable {
    let id: UUID
    let state: CaptureSessionState
    let directory: URL
    let capturedAt: Date
    let sampleRate: Double
    let channelCount: Int
    let inputDeviceUID: String?
    let destination: String
    let recoveryJobID: UUID?
    let libraryDictationID: Int64?
    let assetKind: RecoveryAssetKind
    let failureMessage: String?
    let contentHash: String?
    /// Durable voice command snapshot (PLAN.md PR A, item 1b) — written once, atomically with (or
    /// immediately before) the `.capturing -> .staged` transition at Recording stop, via
    /// `CaptureLedgerStoring.recordVoiceCommandSnapshot`. `nil`/`nil` for every OTHER transition
    /// (silent/damaged/cancelling/still-capturing) and for sessions created before this feature —
    /// nullable at every level; "absent" means "legacy or never staged", not "disabled". Both
    /// fields are set together or not at all.
    var voiceCommandsEnabled: Bool? = nil
    var commandKeywords: [String]? = nil
}

struct CaptureSegment: Sendable, Equatable {
    let captureID: UUID
    let ordinal: Int
    let url: URL
    let sampleCount: Int
    let contentHash: String
}

struct CaptureStartRequest: Sendable, Equatable {
    let id: UUID
    let directory: URL
    let capturedAt: Date
    let sampleRate: Double
    let channelCount: Int
    let inputDeviceUID: String?
    let destination: String
}
