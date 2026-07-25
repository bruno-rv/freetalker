import Foundation
import Testing
@testable import FreeTalker

/// The `includeSpeakerLabels` toggle TranscriptExporter gained for the automation surface
/// (BRAINSTORM_AUTOMATION_SURFACE.md capability 1: "with or without speaker labels"). Existing
/// call sites (the Imports window export menu) never pass this, so the default-`true` behavior is
/// covered incidentally by leaving it out below.
@Suite("TranscriptExporter speaker labels")
struct TranscriptExporterTests {
    private static let segments = [
        AttributedTranscriptSegment(start: 0, end: 1.5, text: "Hello there.", speakerID: "A"),
        AttributedTranscriptSegment(start: 1.5, end: 3, text: "General Kenobi.", speakerID: "B"),
    ]
    private static let names = ["A": "Obi-Wan", "B": "Grievous"]

    @Test func plainTextWithLabels() {
        let output = TranscriptExporter().export(Self.segments, format: .plainText, speakerNames: Self.names)
        #expect(output == "Obi-Wan: Hello there.\nGrievous: General Kenobi.")
    }

    @Test func plainTextWithoutLabels() {
        let output = TranscriptExporter().export(
            Self.segments, format: .plainText, speakerNames: Self.names, includeSpeakerLabels: false
        )
        #expect(output == "Hello there.\nGeneral Kenobi.")
    }

    @Test func markdownWithoutLabelsOmitsBoldSpeakerPrefix() {
        let output = TranscriptExporter().export(
            Self.segments, format: .markdown, speakerNames: Self.names, includeSpeakerLabels: false
        )
        // Markdown escaping still applies to the text itself (the trailing "." is punctuation
        // TranscriptExporter's escaper backslash-escapes) — only the bold speaker prefix is gone.
        #expect(output == "Hello there\\.\n\nGeneral Kenobi\\.")
        #expect(!output.contains("**"))
    }

    @Test func srtWithoutLabelsOmitsSpeakerPrefixButKeepsCueNumbersAndTimestamps() {
        let output = TranscriptExporter().export(
            Self.segments, format: .srt, speakerNames: Self.names, includeSpeakerLabels: false
        )
        #expect(output.contains("1\n00:00:00,000 --> 00:00:01,500\nHello there."))
        #expect(!output.contains("Obi-Wan"))
    }

    @Test func vttWithoutLabelsOmitsVoiceTagButKeepsCueTiming() {
        let output = TranscriptExporter().export(
            Self.segments, format: .vtt, speakerNames: Self.names, includeSpeakerLabels: false
        )
        #expect(output.contains("00:00:00.000 --> 00:00:01.500\nHello there."))
        #expect(!output.contains("<v "))
    }

    @Test func vttWithLabelsKeepsTheVoiceTag() {
        let output = TranscriptExporter().export(Self.segments, format: .vtt, speakerNames: Self.names)
        #expect(output.contains("<v Obi-Wan>Hello there.</v>"))
    }
}
