import Foundation

public enum VoiceEmbeddingError: Error, Equatable, Sendable {
    case invalidDimension(Int)
    case nonFiniteValue(index: Int)
    case zeroNorm
}

public struct VoiceEmbedding: Equatable, Sendable {
    public static let dimension = 256

    public let values: [Float]

    public init(validating raw: [Float]) throws {
        guard raw.count == Self.dimension else {
            throw VoiceEmbeddingError.invalidDimension(raw.count)
        }

        for (index, value) in raw.enumerated() where !value.isFinite {
            throw VoiceEmbeddingError.nonFiniteValue(index: index)
        }

        let squaredNorm = raw.reduce(into: 0.0) { sum, value in
            sum += Double(value) * Double(value)
        }
        guard squaredNorm >= 1e-24 else {
            throw VoiceEmbeddingError.zeroNorm
        }

        let norm = squaredNorm.squareRoot()
        values = raw.map { Float(Double($0) / norm) }
    }

    public func cosineDistance(to other: VoiceEmbedding) -> Double {
        let similarity = zip(values, other.values).reduce(into: 0.0) { sum, pair in
            sum += Double(pair.0) * Double(pair.1)
        }
        return 1 - min(1, max(-1, similarity))
    }
}
