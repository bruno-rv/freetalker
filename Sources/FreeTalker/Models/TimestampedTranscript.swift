import Foundation

struct TranscriptSegment: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

struct SpeakerTurn: Sendable, Equatable {
    let speakerID: String
    let start: TimeInterval
    let end: TimeInterval
}

struct AttributedTranscriptSegment: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let speakerID: String?
}

enum TranscriptFormat: Sendable, CaseIterable {
    case plainText
    case markdown
    case srt
    case vtt
}
