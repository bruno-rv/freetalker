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
