import Foundation

struct TimelineJoiner: Sendable {
    func join(
        transcript: [TranscriptSegment],
        speakers: [SpeakerTurn]
    ) -> [AttributedTranscriptSegment] {
        transcript.map { segment in
            let speakerID: String?
            if isValid(start: segment.start, end: segment.end) {
                let overlappingSpeakers = speakers.reduce(into: Set<String>()) { result, turn in
                    guard !turn.speakerID.isEmpty, isValid(start: turn.start, end: turn.end) else { return }
                    let overlap = min(segment.end, turn.end) - max(segment.start, turn.start)
                    if overlap > 0 {
                        result.insert(turn.speakerID)
                    }
                }
                speakerID = overlappingSpeakers.count == 1 ? overlappingSpeakers.first : nil
            } else {
                speakerID = nil
            }

            return AttributedTranscriptSegment(
                start: segment.start,
                end: segment.end,
                text: segment.text,
                speakerID: speakerID
            )
        }
    }

    private func isValid(start: TimeInterval, end: TimeInterval) -> Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start
    }
}
