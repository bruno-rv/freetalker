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

public enum ThresholdMetricsError: Error, Equatable, Sendable {
    case invalidThreshold
    case negativeCount
    case inconsistentCohort
    case invalidThresholdOrder
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
    ) throws {
        guard threshold.isFinite, threshold >= 0, threshold <= 1 else {
            throw ThresholdMetricsError.invalidThreshold
        }
        guard falseMatchCount >= 0,
              missedMatchCount >= 0,
              trueMatchCount >= 0,
              trueRejectCount >= 0 else {
            throw ThresholdMetricsError.negativeCount
        }
        self.init(
            validatedThreshold: threshold,
            falseMatchCount: falseMatchCount,
            missedMatchCount: missedMatchCount,
            trueMatchCount: trueMatchCount,
            trueRejectCount: trueRejectCount
        )
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            threshold: values.decode(Double.self, forKey: .threshold),
            falseMatchCount: values.decode(Int.self, forKey: .falseMatchCount),
            missedMatchCount: values.decode(Int.self, forKey: .missedMatchCount),
            trueMatchCount: values.decode(Int.self, forKey: .trueMatchCount),
            trueRejectCount: values.decode(Int.self, forKey: .trueRejectCount)
        )
    }

    public var falseMatchRate: Double {
        safeRate(falseMatchCount, trueRejectCount)
    }

    public var missedMatchRate: Double {
        safeRate(missedMatchCount, trueMatchCount)
    }

    public var trueMatchRate: Double {
        safeRate(trueMatchCount, missedMatchCount)
    }

    public var trueRejectRate: Double {
        safeRate(trueRejectCount, falseMatchCount)
    }

    private func safeRate(_ numerator: Int, _ other: Int) -> Double {
        let denominator = Double(numerator) + Double(other)
        return denominator == 0 ? 0 : Double(numerator) / denominator
    }

    fileprivate init(
        validatedThreshold threshold: Double,
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
    public static func decodeThresholdMetrics(from data: Data) throws -> [ThresholdMetrics] {
        let metrics = try JSONDecoder().decode([ThresholdMetrics].self, from: data)
        guard let first = metrics.first else { return [] }
        let samePersonTotal = UInt(first.missedMatchCount) + UInt(first.trueMatchCount)
        let differentPersonTotal = UInt(first.falseMatchCount) + UInt(first.trueRejectCount)

        for index in metrics.indices {
            let metric = metrics[index]
            guard UInt(metric.missedMatchCount) + UInt(metric.trueMatchCount) == samePersonTotal,
                  UInt(metric.falseMatchCount) + UInt(metric.trueRejectCount) == differentPersonTotal else {
                throw ThresholdMetricsError.inconsistentCohort
            }
            if index > 0, metrics[index - 1].threshold >= metric.threshold {
                throw ThresholdMetricsError.invalidThresholdOrder
            }
        }
        return metrics
    }

    public static func evaluate(
        _ values: [LabeledDistance],
        thresholds: [Double]
    ) -> [ThresholdMetrics] {
        guard values.allSatisfy(isValid),
              thresholds.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { return [] }
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
                validatedThreshold: threshold,
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
