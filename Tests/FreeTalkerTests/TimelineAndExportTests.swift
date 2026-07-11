import Foundation
import Testing
@testable import FreeTalker

@Suite struct TimelineAndExportTests {
    private let joiner = TimelineJoiner()
    private let exporter = TranscriptExporter()

    @Test func assignsSingleSpeakerAcrossMultipleOverlappingTurns() {
        let result = joiner.join(
            transcript: [.init(start: 1, end: 5, text: "Hello")],
            speakers: [
                .init(speakerID: "speaker", start: 1, end: 2),
                .init(speakerID: "speaker", start: 2, end: 5)
            ]
        )

        #expect(result.map(\.speakerID) == ["speaker"])
    }

    @Test func equalOverlapFromDistinctSpeakersIsAmbiguous() {
        let transcript = [TranscriptSegment(start: 1, end: 3, text: "Tie")]
        let speakers = [
            SpeakerTurn(speakerID: "first", start: 0, end: 2),
            SpeakerTurn(speakerID: "second", start: 2, end: 4)
        ]

        #expect(joiner.join(transcript: transcript, speakers: speakers).first?.speakerID == nil)
    }

    @Test func unequalOverlapFromDistinctSpeakersIsStillAmbiguous() {
        let transcript = [TranscriptSegment(start: 1, end: 5, text: "Overlap")]
        let speakers = [
            SpeakerTurn(speakerID: "brief", start: 1, end: 2),
            SpeakerTurn(speakerID: "dominant", start: 2, end: 5)
        ]

        #expect(joiner.join(transcript: transcript, speakers: speakers).first?.speakerID == nil)
    }

    @Test func ignoresInvalidTurnsAndUsesUnknownWithoutPositiveOverlap() {
        let transcript = [
            TranscriptSegment(start: 0, end: 1, text: "Before"),
            TranscriptSegment(start: 4, end: 4, text: "Point")
        ]
        let speakers = [
            SpeakerTurn(speakerID: "", start: 0, end: 1),
            SpeakerTurn(speakerID: "reversed", start: 5, end: 3)
        ]

        #expect(joiner.join(transcript: transcript, speakers: speakers).map(\.speakerID) == [nil, nil])
        #expect(joiner.join(transcript: transcript, speakers: []).map(\.speakerID) == [nil, nil])
    }

    @Test func invalidTranscriptIntervalsRemainUnattributed() {
        let invalid = [
            TranscriptSegment(start: .nan, end: 1, text: "nan"),
            TranscriptSegment(start: 0, end: .infinity, text: "positive infinity"),
            TranscriptSegment(start: -.infinity, end: 1, text: "negative infinity"),
            TranscriptSegment(start: -1, end: 1, text: "negative"),
            TranscriptSegment(start: 1, end: 1, text: "zero"),
            TranscriptSegment(start: 2, end: 1, text: "reversed")
        ]
        let speaker = [SpeakerTurn(speakerID: "speaker", start: 0, end: 10)]

        #expect(joiner.join(transcript: invalid, speakers: speaker).map(\.speakerID) == Array(repeating: nil, count: invalid.count))
    }

    @Test func invalidSpeakerIntervalsNeverReceiveAttribution() {
        let transcript = [TranscriptSegment(start: 0, end: 10, text: "Transcript")]
        let invalid = [
            SpeakerTurn(speakerID: "nan", start: .nan, end: 1),
            SpeakerTurn(speakerID: "positive infinity", start: 0, end: .infinity),
            SpeakerTurn(speakerID: "negative infinity", start: -.infinity, end: 1),
            SpeakerTurn(speakerID: "negative", start: -1, end: 1),
            SpeakerTurn(speakerID: "zero", start: 1, end: 1),
            SpeakerTurn(speakerID: "reversed", start: 2, end: 1)
        ]

        #expect(joiner.join(transcript: transcript, speakers: invalid).first?.speakerID == nil)
    }

    @Test func speakerNamesAreResolvedAtExportTime() {
        let segments = joiner.join(
            transcript: [.init(start: 0, end: 1, text: "Hello")],
            speakers: [.init(speakerID: "speaker-1", start: 0, end: 1)]
        )

        let first = exporter.export(segments, format: .plainText, speakerNames: ["speaker-1": "Alice"])
        let renamed = exporter.export(segments, format: .plainText, speakerNames: ["speaker-1": "Dr. Rivera"])

        #expect(first == "Alice: Hello")
        #expect(renamed == "Dr. Rivera: Hello")
    }

    @Test func exportsAllFourFormatsAndEscapesTheirSyntax() {
        let segments = [AttributedTranscriptSegment(
            start: 0,
            end: 1.25,
            text: "Use <this> & *that* --> now",
            speakerID: "speaker"
        )]
        let names = ["speaker": "A & B"]

        #expect(exporter.export(segments, format: .plainText, speakerNames: names) == "A & B: Use <this> & *that* --> now")
        #expect(exporter.export(segments, format: .markdown, speakerNames: names) == "**A &amp; B:** Use &lt;this&gt; &amp; \u{005C}*that\u{005C}* \u{005C}-\u{005C}-&gt; now")
        #expect(exporter.export(segments, format: .srt, speakerNames: names) == "1\n00:00:00,000 --> 00:00:01,250\nA & B: Use <this> & *that* --&gt; now")
        #expect(exporter.export(segments, format: .vtt, speakerNames: names) == "WEBVTT\n\n00:00:00.000 --> 00:00:01.250\n<v A &amp; B>Use &lt;this&gt; &amp; *that* --&gt; now</v>")
    }

    @Test func markdownEscapesAllFormattingAndLinkDelimiters() {
        let punctuation = #"\`*_{}[]<>()#+-.! &"#
        let segment = AttributedTranscriptSegment(start: 0, end: 1, text: punctuation, speakerID: "speaker")

        let markdown = exporter.export([segment], format: .markdown, speakerNames: ["speaker": punctuation])

        let escaped = "\\\\\\`\\*\\_\\{\\}\\[\\]&lt;&gt;\\(\\)\\#\\+\\-\\.\\! &amp;"
        #expect(markdown == "**\(escaped):** \(escaped)")
    }

    @Test func subtitlesNormalizeInvalidOverlappingAndZeroDurationCues() {
        let segments = [
            AttributedTranscriptSegment(start: 2, end: 1, text: "first", speakerID: nil),
            AttributedTranscriptSegment(start: -4, end: 0, text: "second", speakerID: nil),
            AttributedTranscriptSegment(start: 0, end: 10, text: "third", speakerID: nil)
        ]

        let srt = exporter.export(segments, format: .srt, speakerNames: [:])
        #expect(srt.contains("00:00:02,000 --> 00:00:02,001"))
        #expect(srt.contains("00:00:02,001 --> 00:00:02,002"))
        #expect(srt.contains("00:00:02,002 --> 00:00:10,000"))
    }

    @Test func emptyTranscriptExportsValidEmptyRepresentations() {
        #expect(joiner.join(transcript: [], speakers: []).isEmpty)
        #expect(exporter.export([], format: .plainText, speakerNames: [:]).isEmpty)
        #expect(exporter.export([], format: .markdown, speakerNames: [:]).isEmpty)
        #expect(exporter.export([], format: .srt, speakerNames: [:]).isEmpty)
        #expect(exporter.export([], format: .vtt, speakerNames: [:]) == "WEBVTT")
    }

    @Test func unknownSpeakerGetsStableFallbackLabel() {
        let segment = AttributedTranscriptSegment(start: 0, end: 1, text: "Unknown", speakerID: nil)
        #expect(exporter.export([segment], format: .plainText, speakerNames: [:]) == "Unknown Speaker: Unknown")
    }
}
