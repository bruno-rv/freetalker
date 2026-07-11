import Foundation

struct TimelineJoiner: Sendable {
    func join(
        transcript: [TranscriptSegment],
        speakers: [SpeakerTurn]
    ) -> [AttributedTranscriptSegment] {
        transcript.map { segment in
            let speakerID: String?
            if isValid(start: segment.start, end: segment.end) {
                let intervals = speakers.compactMap { turn -> SpeakerInterval? in
                    guard !turn.speakerID.isEmpty, isValid(start: turn.start, end: turn.end) else { return nil }
                    let start = max(segment.start, turn.start)
                    let end = min(segment.end, turn.end)
                    guard end > start else { return nil }
                    return SpeakerInterval(speakerID: turn.speakerID, start: start, end: end)
                }
                speakerID = attributedSpeaker(in: intervals)
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

    private func attributedSpeaker(in intervals: [SpeakerInterval]) -> String? {
        for firstIndex in intervals.indices {
            for secondIndex in intervals.indices where secondIndex > firstIndex {
                let first = intervals[firstIndex]
                let second = intervals[secondIndex]
                guard first.speakerID != second.speakerID else { continue }
                if min(first.end, second.end) > max(first.start, second.start) {
                    return nil
                }
            }
        }

        let durations = Dictionary(grouping: intervals, by: \.speakerID).mapValues(unionDuration)
        guard let greatest = durations.values.max() else { return nil }
        let winners = durations.filter { $0.value == greatest }.map(\.key)
        return winners.count == 1 ? winners[0] : nil
    }

    private func unionDuration(_ intervals: [SpeakerInterval]) -> TimeInterval {
        let sorted = intervals.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        guard var current = sorted.first else { return 0 }
        var duration = 0.0
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                current = SpeakerInterval(
                    speakerID: current.speakerID,
                    start: current.start,
                    end: max(current.end, interval.end)
                )
            } else {
                duration += current.end - current.start
                current = interval
            }
        }
        return duration + current.end - current.start
    }
}

private struct SpeakerInterval {
    let speakerID: String
    let start: TimeInterval
    let end: TimeInterval
}
