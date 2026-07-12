import Foundation
import Testing
@testable import VoiceProfileCore

@Suite("Calibration metrics")
struct CalibrationMetricsTests {
    @Test func equalityIsAcceptedAndThresholdsAreSortedDeterministically() throws {
        let values = [
            LabeledDistance(expectedSamePerson: true, distance: 0.2, cleanSpeechSeconds: 1, quality: 0.5),
            LabeledDistance(expectedSamePerson: false, distance: 0.2, cleanSpeechSeconds: 2, quality: nil)
        ]
        let metrics = CalibrationMetrics.evaluate(values, thresholds: [0.3, 0.2, 0.1, 0.2])
        #expect(metrics.map(\.threshold) == [0.1, 0.2, 0.3])
        let expected = try ThresholdMetrics(
            threshold: 0.2, falseMatchCount: 1, missedMatchCount: 0,
            trueMatchCount: 1, trueRejectCount: 0
        )
        #expect(metrics[1] == expected)
    }

    @Test func emptyCohortsHaveSafeRates() {
        let metric = CalibrationMetrics.evaluate([], thresholds: [0.5])[0]
        #expect(metric.falseMatchRate == 0)
        #expect(metric.missedMatchRate == 0)
        #expect(metric.trueMatchRate == 0)
        #expect(metric.trueRejectRate == 0)
    }

    @Test func thresholdGridAcceptsOnlyZeroThroughOneInclusive() {
        #expect(CalibrationMetrics.evaluate([], thresholds: [0, 1]).map(\.threshold) == [0, 1])
        #expect(CalibrationMetrics.evaluate([], thresholds: [0.nextDown]).isEmpty)
        #expect(CalibrationMetrics.evaluate([], thresholds: [1.nextUp]).isEmpty)
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

    @Test func thresholdMetricsRejectInvalidConstructionAndJSON() throws {
        #expect(throws: ThresholdMetricsError.invalidThreshold) {
            try ThresholdMetrics(
                threshold: 1.nextUp, falseMatchCount: 0, missedMatchCount: 0,
                trueMatchCount: 0, trueRejectCount: 0
            )
        }
        #expect(throws: ThresholdMetricsError.negativeCount) {
            try ThresholdMetrics(
                threshold: 0.5, falseMatchCount: -1, missedMatchCount: 0,
                trueMatchCount: 0, trueRejectCount: 0
            )
        }

        for json in [
            #"[{"threshold":1.1,"falseMatchCount":0,"missedMatchCount":0,"trueMatchCount":0,"trueRejectCount":0}]"#,
            #"[{"threshold":0.5,"falseMatchCount":0,"missedMatchCount":-1,"trueMatchCount":0,"trueRejectCount":0}]"#
        ] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode([ThresholdMetrics].self, from: Data(json.utf8))
            }
        }
    }

    @Test func decodedThresholdGridRejectsInconsistentCohortsAndOrdering() {
        let inconsistent = #"""
        [
          {"threshold":0.1,"falseMatchCount":0,"missedMatchCount":1,"trueMatchCount":1,"trueRejectCount":2},
          {"threshold":0.2,"falseMatchCount":1,"missedMatchCount":0,"trueMatchCount":3,"trueRejectCount":1}
        ]
        """#
        #expect(throws: ThresholdMetricsError.inconsistentCohort) {
            try CalibrationMetrics.decodeThresholdMetrics(from: Data(inconsistent.utf8))
        }

        let unsorted = #"""
        [
          {"threshold":0.2,"falseMatchCount":0,"missedMatchCount":1,"trueMatchCount":1,"trueRejectCount":2},
          {"threshold":0.1,"falseMatchCount":1,"missedMatchCount":0,"trueMatchCount":2,"trueRejectCount":1}
        ]
        """#
        #expect(throws: ThresholdMetricsError.invalidThresholdOrder) {
            try CalibrationMetrics.decodeThresholdMetrics(from: Data(unsorted.utf8))
        }
    }

    @Test func validRatesStayBoundedForLargeCounts() throws {
        let metrics = try ThresholdMetrics(
            threshold: 0.5,
            falseMatchCount: Int.max,
            missedMatchCount: Int.max,
            trueMatchCount: Int.max,
            trueRejectCount: Int.max
        )
        #expect((0...1).contains(metrics.falseMatchRate))
        #expect((0...1).contains(metrics.missedMatchRate))
        #expect((0...1).contains(metrics.trueMatchRate))
        #expect((0...1).contains(metrics.trueRejectRate))
    }

    @Test func rejectsNonfiniteDistancesThresholdsAndBinBoundaries() {
        let invalid = [LabeledDistance(expectedSamePerson: true, distance: .nan, cleanSpeechSeconds: 1, quality: nil)]
        #expect(CalibrationMetrics.evaluate(invalid, thresholds: [0.5]).isEmpty)
        #expect(CalibrationMetrics.evaluate([], thresholds: [.infinity]).isEmpty)
        #expect(CalibrationMetrics.evaluate([], thresholds: [-0.1]).isEmpty)
        #expect(CalibrationMetrics.evaluate([], thresholds: [1.nextUp]).isEmpty)
        #expect(CalibrationMetrics.durationBins([], boundaries: [.nan]).isEmpty)
    }
}
