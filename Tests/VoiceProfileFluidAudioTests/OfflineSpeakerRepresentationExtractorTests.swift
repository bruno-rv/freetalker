import FluidAudio
import Foundation
import Testing
import VoiceProfileCore
@testable import VoiceProfileFluidAudio

@Suite struct OfflineSpeakerRepresentationExtractorTests {
    @Test func mapsChunkEmbeddingsByFinalClusterWithDeterministicOrdering() throws {
        var first = Array(repeating: Float(0), count: 256)
        first[0] = 3; first[1] = 4
        var second = Array(repeating: Float(0), count: 256)
        second[2] = 1
        let result = DiarizationResult(
            segments: [
                .init(speakerId: "S2", embedding: [], startTimeSeconds: 2, endTimeSeconds: 4, qualityScore: 0),
                .init(speakerId: "S1", embedding: [], startTimeSeconds: 0, endTimeSeconds: 2, qualityScore: 0)
            ],
            chunkEmbeddings: [
                .init(speakerId: "S2", chunkIndex: 1, speakerIndex: 0, startTimeSeconds: 2, endTimeSeconds: 4, embedding256: second),
                .init(speakerId: "S2", chunkIndex: 0, speakerIndex: 0, startTimeSeconds: 0, endTimeSeconds: 3, embedding256: first),
                .init(speakerId: "S1", chunkIndex: 2, speakerIndex: 0, startTimeSeconds: 4, endTimeSeconds: 5, embedding256: second)
            ]
        )

        let mapped = try OfflineSpeakerRepresentationExtractor.map(result)

        #expect(mapped.turns.map(\.speakerID) == ["S2", "S1"])
        #expect(mapped.speakers.map(\.speakerID) == ["S1", "S2"])
        #expect(mapped.speakers[1].samples.map(\.start) == [0, 2])
        #expect(mapped.speakers[1].cleanSpeechSeconds == 4)
        #expect(abs(mapped.speakers[1].samples[0].embedding.values[0] - 0.6) < 0.000_001)
        #expect(abs(mapped.speakers[1].samples[0].embedding.values[1] - 0.8) < 0.000_001)
    }

    @Test func dropsOnlyMalformedChunksAndTreatsUnavailableChunksAsEmpty() throws {
        let turn = TimedSpeakerSegment(
            speakerId: "S1", embedding: [], startTimeSeconds: 0, endTimeSeconds: 1, qualityScore: 0
        )
        let withoutChunks = try OfflineSpeakerRepresentationExtractor.map(.init(segments: [turn]))
        #expect(withoutChunks.turns.count == 1)
        #expect(withoutChunks.speakers.isEmpty)

        let malformed = ChunkEmbedding(
            speakerId: "S1", chunkIndex: 0, speakerIndex: 0, startTimeSeconds: 0,
            endTimeSeconds: 1, embedding256: [1]
        )
        let withMalformed = try OfflineSpeakerRepresentationExtractor.map(
            .init(segments: [turn], chunkEmbeddings: [malformed])
        )
        #expect(withMalformed.turns.count == 1)
        #expect(withMalformed.speakers.isEmpty)
    }

    @Test func fingerprintIsStableAndDocumentsPinnedEmbeddingStack() {
        let fingerprint = OfflineSpeakerRepresentationExtractor.fingerprint
        #expect(fingerprint.provider == "FluidAudio")
        #expect(fingerprint.modelID.contains("Embedding.mlmodelc"))
        #expect(fingerprint.modelRevision.contains("0.15.5"))
        #expect(fingerprint.preprocessingRevision.contains("FBank.mlmodelc"))
        #expect(fingerprint.dimension == 256)
    }
}
