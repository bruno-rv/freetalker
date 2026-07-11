import Foundation

struct SpeakerSegment: Sendable, Equatable, Identifiable {
    let id: Int64
    let jobID: UUID
    let speakerID: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let transcript: String
}
