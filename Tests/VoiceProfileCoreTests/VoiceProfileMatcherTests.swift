import Foundation
import Testing
@testable import VoiceProfileCore

@Suite("Voice profile matcher")
struct VoiceProfileMatcherTests {
    private let fingerprint = EmbeddingModelFingerprint(
        provider: "test", modelID: "model", modelRevision: "1",
        preprocessingRevision: "1", dimension: 256
    )

    @Test func acceptsExactMatchAndReportsMargin() throws {
        let matcher = try VoiceProfileMatcher(parameters: parameters())
        let result = matcher.candidates(
            speakers: [speaker("speaker", vector(0), seconds: 3)],
            speakerFingerprint: fingerprint,
            prototypes: [prototype("alice", vector(0)), prototype("bob", vector(1))]
        )
        #expect(result == [SpeakerMatchCandidate(
            speakerID: "speaker", participantID: "alice", distance: 0, runnerUpMargin: 1
        )])
    }

    @Test func participantDistanceUsesAllSpeakerSamples() throws {
        let matcher = try VoiceProfileMatcher(parameters: parameters(maximumDistance: 1))
        let mixed = SpeakerRepresentation(
            speakerID: "speaker",
            samples: [
                SpeakerEmbeddingSample(embedding: vector(0), start: 0, end: 1, quality: nil),
                SpeakerEmbeddingSample(embedding: vector(1), start: 1, end: 2, quality: nil)
            ],
            cleanSpeechSeconds: 2
        )
        let result = matcher.candidates(
            speakers: [mixed], speakerFingerprint: fingerprint,
            prototypes: [prototype("alice", vector(0))]
        )
        #expect(result.count == 1)
        #expect(abs(result[0].distance - 0.5) < 0.000_001)
    }

    @Test func rejectsDistanceAtAboveThresholdButAcceptsEquality() throws {
        let matcher = try VoiceProfileMatcher(parameters: parameters(maximumDistance: 1))
        let speaker = speaker("speaker", vector(0), seconds: 3)
        #expect(matcher.candidates(
            speakers: [speaker], speakerFingerprint: fingerprint,
            prototypes: [prototype("alice", vector(1))]
        ).count == 1)

        let strict = try VoiceProfileMatcher(parameters: parameters(maximumDistance: 0.99))
        #expect(strict.candidates(
            speakers: [speaker], speakerFingerprint: fingerprint,
            prototypes: [prototype("alice", vector(1))]
        ).isEmpty)
    }

    @Test func rejectsAmbiguousAndShortSpeakers() throws {
        let ambiguous = try VoiceProfileMatcher(parameters: parameters(minimumMargin: 0.1))
        let prototypes = [prototype("alice", vector(0)), prototype("bob", vector(0))]
        #expect(ambiguous.candidates(
            speakers: [speaker("s", vector(0), seconds: 3)],
            speakerFingerprint: fingerprint, prototypes: prototypes
        ).isEmpty)

        let duration = try VoiceProfileMatcher(parameters: parameters(minimumSeconds: 3))
        #expect(duration.candidates(
            speakers: [speaker("s", vector(0), seconds: 2.99)],
            speakerFingerprint: fingerprint, prototypes: [prototype("alice", vector(0))]
        ).isEmpty)
    }

    @Test func rejectsIncompatiblePrototypes() throws {
        let other = EmbeddingModelFingerprint(
            provider: "other", modelID: "model", modelRevision: "1",
            preprocessingRevision: "1", dimension: 256
        )
        let matcher = try VoiceProfileMatcher(parameters: parameters())
        #expect(matcher.candidates(
            speakers: [speaker("s", vector(0), seconds: 3)],
            speakerFingerprint: fingerprint,
            prototypes: [EnrollmentPrototype(participantID: "alice", embedding: vector(0), fingerprint: other)]
        ).isEmpty)
    }

    @Test func assignmentIsGlobalOneToOneAndIndependentOfInputOrder() throws {
        let matcher = try VoiceProfileMatcher(parameters: parameters(maximumDistance: 2))
        let speakers = [
            speaker("s1", angle: 0.10),
            speaker("s2", angle: 0.01)
        ]
        let prototypes = [
            prototype("alice", angle: 0),
            prototype("bob", angle: 0.30)
        ]
        let result = matcher.candidates(
            speakers: speakers, speakerFingerprint: fingerprint, prototypes: prototypes
        )
        #expect(result.map(\.speakerID) == ["s1", "s2"])
        #expect(result.map(\.participantID) == ["bob", "alice"])
        #expect(abs(result[0].distance - cosineDistance(0.10, 0.30)) < 0.000_001)
        #expect(abs(result[1].distance - cosineDistance(0.01, 0)) < 0.000_001)
        #expect(matcher.candidates(
            speakers: speakers.reversed(), speakerFingerprint: fingerprint,
            prototypes: prototypes.reversed()
        ) == result)
    }

    @Test func stableTiesUseIDsAndUnknownNodesCoverRectangles() throws {
        let matcher = try VoiceProfileMatcher(parameters: parameters(maximumDistance: 2))
        let tied = matcher.candidates(
            speakers: [speaker("z", vector(0), seconds: 3), speaker("a", vector(0), seconds: 3)],
            speakerFingerprint: fingerprint,
            prototypes: [prototype("bob", vector(0)), prototype("alice", vector(0))]
        )
        #expect(tied.map(\.speakerID) == ["a", "z"])
        #expect(tied.map(\.participantID) == ["alice", "bob"])

        #expect(matcher.candidates(speakers: [], speakerFingerprint: fingerprint, prototypes: []).isEmpty)
        #expect(matcher.candidates(
            speakers: [speaker("a", vector(0), seconds: 3)],
            speakerFingerprint: fingerprint, prototypes: []
        ).isEmpty)
        #expect(matcher.candidates(
            speakers: [speaker("a", vector(0), seconds: 3), speaker("b", vector(0), seconds: 3)],
            speakerFingerprint: fingerprint, prototypes: [prototype("alice", vector(0))]
        ).count == 1)
    }

    @Test(arguments: [
        (Double.nan, 0.0, 0.0), (.infinity, 0.0, 0.0),
        (-0.1, 0.0, 0.0), (2.1, 0.0, 0.0),
        (1.0, -0.1, 0.0), (1.0, 2.1, 0.0), (1.0, 0.0, -0.1)
    ])
    func invalidParametersAreRejected(values: (Double, Double, Double)) {
        #expect(throws: MatchingParametersError.self) {
            try MatchingParameters(
                maximumDistance: values.0,
                minimumRunnerUpMargin: values.1,
                minimumCleanSpeechSeconds: values.2
            )
        }
    }

    private func parameters(
        maximumDistance: Double = 0.5,
        minimumMargin: Double = 0,
        minimumSeconds: Double = 1
    ) throws -> MatchingParameters {
        try MatchingParameters(
            maximumDistance: maximumDistance,
            minimumRunnerUpMargin: minimumMargin,
            minimumCleanSpeechSeconds: minimumSeconds
        )
    }

    private func vector(_ index: Int) -> VoiceEmbedding {
        var values = Array(repeating: Float.zero, count: 256)
        values[index] = 1
        return try! VoiceEmbedding(validating: values)
    }

    private func vector(angle: Double) -> VoiceEmbedding {
        var values = Array(repeating: Float.zero, count: 256)
        values[0] = Float(cos(angle)); values[1] = Float(sin(angle))
        return try! VoiceEmbedding(validating: values)
    }

    private func speaker(_ id: String, _ embedding: VoiceEmbedding, seconds: Double) -> SpeakerRepresentation {
        SpeakerRepresentation(
            speakerID: id,
            samples: [SpeakerEmbeddingSample(embedding: embedding, start: 0, end: seconds, quality: nil)],
            cleanSpeechSeconds: seconds
        )
    }

    private func speaker(_ id: String, angle: Double) -> SpeakerRepresentation {
        speaker(id, vector(angle: angle), seconds: 3)
    }

    private func prototype(_ id: String, _ embedding: VoiceEmbedding) -> EnrollmentPrototype {
        EnrollmentPrototype(participantID: id, embedding: embedding, fingerprint: fingerprint)
    }

    private func prototype(_ id: String, angle: Double) -> EnrollmentPrototype {
        prototype(id, vector(angle: angle))
    }

    private func cosineDistance(_ lhs: Double, _ rhs: Double) -> Double {
        1 - (cos(lhs) * cos(rhs) + sin(lhs) * sin(rhs))
    }
}
