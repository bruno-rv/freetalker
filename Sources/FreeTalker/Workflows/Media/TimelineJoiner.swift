import Foundation

struct TimelineJoiner: Sendable {
    func join(
        transcript: [TranscriptSegment],
        speakers: [SpeakerTurn]
    ) -> [AttributedTranscriptSegment] {
        transcript.map { segment in
            let speakerID = speakers.enumerated().reduce(
                into: (index: Int.max, overlap: 0.0, speakerID: Optional<String>.none)
            ) { best, candidate in
                let turn = candidate.element
                guard !turn.speakerID.isEmpty, turn.end > turn.start else { return }
                let overlap = min(segment.end, turn.end) - max(segment.start, turn.start)
                guard overlap > 0 else { return }
                if overlap > best.overlap || (overlap == best.overlap && candidate.offset < best.index) {
                    best = (candidate.offset, overlap, turn.speakerID)
                }
            }.speakerID

            return AttributedTranscriptSegment(
                start: segment.start,
                end: segment.end,
                text: segment.text,
                speakerID: speakerID
            )
        }
    }
}
