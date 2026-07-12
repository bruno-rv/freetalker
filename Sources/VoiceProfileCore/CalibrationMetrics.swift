import Foundation

public struct LabeledDistance: Codable, Equatable, Sendable {
    public let expectedSamePerson: Bool
    public let distance: Double
    public let cleanSpeechSeconds: Double
    public let quality: Double?

    public init(
        expectedSamePerson: Bool,
        distance: Double,
        cleanSpeechSeconds: Double,
        quality: Double?
    ) {
        self.expectedSamePerson = expectedSamePerson
        self.distance = distance
        self.cleanSpeechSeconds = cleanSpeechSeconds
        self.quality = quality
    }
}

public struct ThresholdMetrics: Codable, Equatable, Sendable {
    public let threshold: Double
    public let falseMatchCount: Int
    public let missedMatchCount: Int
    public let trueMatchCount: Int
    public let trueRejectCount: Int

    public init(
        threshold: Double,
        falseMatchCount: Int,
        missedMatchCount: Int,
        trueMatchCount: Int,
        trueRejectCount: Int
    ) {
        self.threshold = threshold
        self.falseMatchCount = falseMatchCount
        self.missedMatchCount = missedMatchCount
        self.trueMatchCount = trueMatchCount
        self.trueRejectCount = trueRejectCount
    }

    public var falseMatchRate: Double {
        safeRate(falseMatchCount, falseMatchCount + trueRejectCount)
    }

    public var missedMatchRate: Double {
        safeRate(missedMatchCount, missedMatchCount + trueMatchCount)
    }

    public var trueMatchRate: Double {
        safeRate(trueMatchCount, missedMatchCount + trueMatchCount)
    }

    public var trueRejectRate: Double {
        safeRate(trueRejectCount, falseMatchCount + trueRejectCount)
    }

    private func safeRate(_ numerator: Int, _ denominator: Int) -> Double {
        denominator == 0 ? 0 : Double(numerator) / Double(denominator)
    }
}

public struct CalibrationBin: Codable, Equatable, Sendable {
    public let lowerBound: Double?
    public let upperBound: Double?
    public let count: Int

    public init(lowerBound: Double?, upperBound: Double?, count: Int) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.count = count
    }
}

public enum CalibrationMetrics {
    public static func evaluate(
        _ values: [LabeledDistance],
        thresholds: [Double]
    ) -> [ThresholdMetrics] {
        guard values.allSatisfy(isValid),
              thresholds.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 2 }) else { return [] }
        return Array(Set(thresholds)).sorted().map { threshold in
            var falseMatches = 0
            var missedMatches = 0
            var trueMatches = 0
            var trueRejects = 0
            for value in values {
                let accepted = value.distance <= threshold
                switch (value.expectedSamePerson, accepted) {
                case (true, true): trueMatches += 1
                case (true, false): missedMatches += 1
                case (false, true): falseMatches += 1
                case (false, false): trueRejects += 1
                }
            }
            return ThresholdMetrics(
                threshold: threshold,
                falseMatchCount: falseMatches,
                missedMatchCount: missedMatches,
                trueMatchCount: trueMatches,
                trueRejectCount: trueRejects
            )
        }
    }

    public static func durationBins(
        _ values: [LabeledDistance],
        boundaries: [Double]
    ) -> [CalibrationBin] {
        guard values.allSatisfy(isValid) else { return [] }
        return bins(values.map(\.cleanSpeechSeconds), boundaries: boundaries)
    }

    public static func qualityBins(
        _ values: [LabeledDistance],
        boundaries: [Double]
    ) -> [CalibrationBin] {
        guard values.allSatisfy(isValid) else { return [] }
        return bins(values.compactMap(\.quality), boundaries: boundaries)
    }

    private static func bins(_ values: [Double], boundaries: [Double]) -> [CalibrationBin] {
        guard boundaries.allSatisfy(\.isFinite) else { return [] }
        let boundaries = Array(Set(boundaries)).sorted()
        return (0...boundaries.count).map { index in
            let lower = index == 0 ? nil : boundaries[index - 1]
            let upper = index == boundaries.count ? nil : boundaries[index]
            let count = values.count { value in
                (lower == nil || value >= lower!) && (upper == nil || value < upper!)
            }
            return CalibrationBin(lowerBound: lower, upperBound: upper, count: count)
        }
    }

    private static func isValid(_ value: LabeledDistance) -> Bool {
        value.distance.isFinite
            && value.cleanSpeechSeconds.isFinite
            && value.cleanSpeechSeconds >= 0
            && (value.quality?.isFinite ?? true)
    }
}
