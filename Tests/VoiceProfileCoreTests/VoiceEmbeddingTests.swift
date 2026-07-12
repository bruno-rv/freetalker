import Foundation
import Testing
@testable import VoiceProfileCore

@Suite struct VoiceEmbeddingTests {
    @Test func validatesAndNormalizesExactly256FiniteValues() throws {
        var raw = Array(repeating: Float(0), count: 256)
        raw[0] = 3
        raw[1] = 4

        let embedding = try VoiceEmbedding(validating: raw)

        #expect(abs(embedding.values[0] - 0.6) < 0.000_001)
        #expect(abs(embedding.values[1] - 0.8) < 0.000_001)
    }

    @Test(arguments: [255, 257])
    func rejectsWrongDimensions(_ count: Int) {
        #expect(throws: VoiceEmbeddingError.invalidDimension(count)) {
            try VoiceEmbedding(validating: Array(repeating: 1, count: count))
        }
    }

    @Test(arguments: [(Float.nan, 3), (.infinity, 27), (-.infinity, 255)])
    func rejectsNonFiniteValues(_ value: Float, _ index: Int) {
        var raw = Array(repeating: Float(1), count: 256)
        raw[index] = value

        #expect(throws: VoiceEmbeddingError.nonFiniteValue(index: index)) {
            try VoiceEmbedding(validating: raw)
        }
    }

    @Test func rejectsAllZeroVector() {
        #expect(throws: VoiceEmbeddingError.zeroNorm) {
            try VoiceEmbedding(validating: Array(repeating: 0, count: 256))
        }
    }

    @Test func rejectsNormBelowOneTrillionth() {
        var raw = Array(repeating: Float(0), count: 256)
        raw[0] = 0.5e-12

        #expect(throws: VoiceEmbeddingError.zeroNorm) {
            try VoiceEmbedding(validating: raw)
        }
    }

    @Test func preservesStableFloat32ValuesAndEquality() throws {
        var raw = Array(repeating: Float(0), count: 256)
        raw[0] = 1

        let first = try VoiceEmbedding(validating: raw)
        let second = try VoiceEmbedding(validating: raw)

        #expect(first == second)
        #expect(first.values == raw)
        #expect(type(of: first.values[0]) == Float.self)
    }

    @Test func computesClampedCosineDistance() throws {
        var firstRaw = Array(repeating: Float(0), count: 256)
        firstRaw[0] = 1
        var secondRaw = Array(repeating: Float(0), count: 256)
        secondRaw[1] = 1

        let first = try VoiceEmbedding(validating: firstRaw)
        let same = try VoiceEmbedding(validating: firstRaw)
        let orthogonal = try VoiceEmbedding(validating: secondRaw)

        #expect(first.cosineDistance(to: same) == 0)
        #expect(first.cosineDistance(to: orthogonal) == 1)
    }

    @Test func float32NormalizationRoundingStillProducesExactBoundedDistances() throws {
        var positiveRaw = Array(repeating: Float(0), count: 256)
        for index in 0..<31 { positiveRaw[index] = 1 }
        let negativeRaw = positiveRaw.map(-)
        let positive = try VoiceEmbedding(validating: positiveRaw)
        let negative = try VoiceEmbedding(validating: negativeRaw)
        let roundedSelfDot = positive.values.reduce(into: 0.0) { sum, value in
            sum += Double(value) * Double(value)
        }
        #expect(roundedSelfDot > 1)
        #expect(positive.cosineDistance(to: positive) == 0)
        #expect(positive.cosineDistance(to: negative) == 2)
        for lhs in [positive, negative] {
            for rhs in [positive, negative] {
                #expect((0...2).contains(lhs.cosineDistance(to: rhs)))
            }
        }
    }
}
