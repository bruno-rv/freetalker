import Foundation

struct TranscriptExporter: Sendable {
    /// Largest timestamp emitted by SRT/VTT exports: 99:59:59.999.
    static let maximumSubtitleTime: TimeInterval = 359_999.999

    func export(
        _ segments: [AttributedTranscriptSegment],
        format: TranscriptFormat,
        speakerNames: [String: String]
    ) -> String {
        switch format {
        case .plainText:
            return segments.map { "\(label(for: $0, names: speakerNames)): \($0.text)" }.joined(separator: "\n")
        case .markdown:
            return segments.map {
                "**\(escapeMarkup(label(for: $0, names: speakerNames), markdown: true)):** \(escapeMarkup($0.text, markdown: true))"
            }.joined(separator: "\n\n")
        case .srt:
            return cues(for: segments).enumerated().map { index, cue in
                let text = cue.segment.text.replacingOccurrences(of: "-->", with: "--&gt;")
                return "\(index + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n\(label(for: cue.segment, names: speakerNames)): \(text)"
            }.joined(separator: "\n\n")
        case .vtt:
            let body = cues(for: segments).map { cue in
                let speaker = escapeMarkup(label(for: cue.segment, names: speakerNames), markdown: false)
                let text = escapeMarkup(cue.segment.text, markdown: false)
                return "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n<v \(speaker)>\(text)</v>"
            }.joined(separator: "\n\n")
            return body.isEmpty ? "WEBVTT" : "WEBVTT\n\n\(body)"
        }
    }

    private func label(for segment: AttributedTranscriptSegment, names: [String: String]) -> String {
        guard let speakerID = segment.speakerID else { return "Unknown Speaker" }
        return names[speakerID] ?? speakerID
    }

    private func escapeMarkup(_ value: String, markdown: Bool) -> String {
        let markdownPunctuation = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
        return value.reduce(into: "") { result, character in
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default:
                if markdown && markdownPunctuation.contains(character) {
                    result.append("\\")
                }
                result.append(character)
            }
        }
    }

    private func cues(for segments: [AttributedTranscriptSegment]) -> [(segment: AttributedTranscriptSegment, start: TimeInterval, end: TimeInterval)] {
        let minimumDuration = 0.001
        let latestStart = Self.maximumSubtitleTime - minimumDuration
        var previousEnd = 0.0
        var cues: [(AttributedTranscriptSegment, TimeInterval, TimeInterval)] = []
        for segment in segments where previousEnd <= latestStart {
            let rawStart = segment.start.isFinite ? min(max(0, segment.start), latestStart) : 0
            let rawEnd = segment.end.isFinite ? min(max(0, segment.end), Self.maximumSubtitleTime) : rawStart
            let start = min(max(previousEnd, rawStart), latestStart)
            let end = min(max(start + minimumDuration, rawEnd), Self.maximumSubtitleTime)
            previousEnd = end
            cues.append((segment, start, end))
        }
        return cues
    }

    private func timestamp(_ seconds: TimeInterval, separator: Character) -> String {
        let clamped = min(max(0, seconds), Self.maximumSubtitleTime)
        let milliseconds = Int((clamped * 1_000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60_000 % 60
        let seconds = milliseconds / 1_000 % 60
        let remainder = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, seconds, String(separator), remainder)
    }
}
