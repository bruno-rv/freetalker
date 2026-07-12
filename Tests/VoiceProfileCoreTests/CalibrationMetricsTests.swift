import Foundation
import Testing
@testable import VoiceProfileCore

@Suite("Calibration metrics")
struct CalibrationMetricsTests {
    @Test func equalityIsAcceptedAndThresholdsAreSortedDeterministically() {
        let values = [
            LabeledDistance(expectedSamePerson: true, distance: 0.2, cleanSpeechSeconds: 1, quality: 0.5),
            LabeledDistance(expectedSamePerson: false, distance: 0.2, cleanSpeechSeconds: 2, quality: nil)
        ]
        let metrics = CalibrationMetrics.evaluate(values, thresholds: [0.3, 0.2, 0.1, 0.2])
        #expect(metrics.map(\.threshold) == [0.1, 0.2, 0.3])
        #expect(metrics[1] == ThresholdMetrics(
            threshold: 0.2, falseMatchCount: 1, missedMatchCount: 0,
            trueMatchCount: 1, trueRejectCount: 0
        ))
    }

    @Test func emptyCohortsHaveSafeRates() {
        let metric = CalibrationMetrics.evaluate([], thresholds: [0.5])[0]
        #expect(metric.falseMatchRate == 0)
        #expect(metric.missedMatchRate == 0)
        #expect(metric.trueMatchRate == 0)
        #expect(metric.trueRejectRate == 0)
    }

    @Test func durationAndQualityBinsUseLowerInclusiveUpperExclusiveBounds() {
        let values = [
            LabeledDistance(expectedSamePerson: true, distance: 0.1, cleanSpeechSeconds: 0, quality: nil),
            LabeledDistance(expectedSamePerson: true, distance: 0.2, cleanSpeechSeconds: 1, quality: 0),
            LabeledDistance(expectedSamePerson: false, distance: 0.3, cleanSpeechSeconds: 2, quality: 0.5),
            LabeledDistance(expectedSamePerson: false, distance: 0.4, cleanSpeechSeconds: 3, quality: 1)
        ]
        #expect(CalibrationMetrics.durationBins(values, boundaries: [1, 2]).map(\.count) == [1, 1, 2])
        #expect(CalibrationMetrics.qualityBins(values, boundaries: [0.5, 1]).map(\.count) == [1, 1, 1])
    }

    @Test func codableValuesRoundTripWithDeterministicJSON() throws {
        let values = [LabeledDistance(
            expectedSamePerson: true, distance: 0.2,
            cleanSpeechSeconds: 3, quality: 0.8
        )]
        let metrics = CalibrationMetrics.evaluate(values, thresholds: [0.2])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(metrics)
        let second = try encoder.encode(metrics)
        #expect(first == second)
        #expect(try JSONDecoder().decode([ThresholdMetrics].self, from: first) == metrics)
        #expect(try JSONDecoder().decode([LabeledDistance].self, from: encoder.encode(values)) == values)
    }

    @Test func rejectsNonfiniteDistancesThresholdsAndBinBoundaries() {
        let invalid = [LabeledDistance(expectedSamePerson: true, distance: .nan, cleanSpeechSeconds: 1, quality: nil)]
        #expect(CalibrationMetrics.evaluate(invalid, thresholds: [0.5]).isEmpty)
        #expect(CalibrationMetrics.evaluate([], thresholds: [.infinity]).isEmpty)
        #expect(CalibrationMetrics.evaluate([], thresholds: [-0.1]).isEmpty)
        #expect(CalibrationMetrics.evaluate([], thresholds: [2.1]).isEmpty)
        #expect(CalibrationMetrics.durationBins([], boundaries: [.nan]).isEmpty)
    }
}
