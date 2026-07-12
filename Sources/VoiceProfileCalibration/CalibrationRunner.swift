import Foundation
import VoiceProfileCore
import VoiceProfileFluidAudio

public struct CalibrationRunner: Sendable {
    public typealias Extract = @Sendable (URL) async throws -> OfflineVoiceRepresentationResult
    private let extract: Extract

    public init(extract: @escaping Extract) { self.extract = extract }

    public func run(manifest: CalibrationManifest) async throws -> CalibrationReport {
        try await run(validatedInputs: manifest.validatedInputs())
    }

    public func run(validatedInputs: [ValidatedCalibrationInput]) async throws -> CalibrationReport {
        let samples = validatedInputs.map(\ .sample)
        var records: [Record] = []
        var rejected: [String] = []
        var fingerprint: EmbeddingModelFingerprint?

        for input in validatedInputs {
            let sample = input.sample
            do {
                var result: OfflineVoiceRepresentationResult? = try await input.media.withStableURL { stableURL in
                    try await extract(stableURL)
                }
                guard let extracted = result,
                      fingerprint == nil || fingerprint == extracted.fingerprint,
                      let representation = extracted.speakers.first(where: { $0.speakerID == sample.expectedSpeakerID }),
                      !representation.samples.isEmpty else {
                    result = nil
                    rejected.append(sample.sampleID)
                    continue
                }
                fingerprint = extracted.fingerprint
                records.append(Record(
                    sampleID: sample.sampleID, participantID: sample.participantID,
                    sessionID: sample.sessionID, representation: representation
                ))
                result = nil
            } catch {
                rejected.append(sample.sampleID)
            }
        }

        guard let fingerprint else { throw CalibrationRunnerError.noUsableSamples }
        var distances: [LabeledDistance] = []
        var queryObservations: [LabeledDistance] = []
        var margins: [Double] = []
        let participantIDs = Set(records.map(\ .participantID)).sorted()
        for query in records.sorted(by: { $0.sampleID < $1.sampleID }) {
            var perParticipant: [(String, Double)] = []
            for participantID in participantIDs {
                let enrollment = records.filter {
                    $0.participantID == participantID && $0.sessionID != query.sessionID
                }
                let values = enrollment.flatMap(\ .representation.samples).flatMap { prototype in
                    query.representation.samples.map { $0.embedding.cosineDistance(to: prototype.embedding) }
                }
                guard !values.isEmpty else { continue }
                perParticipant.append((participantID, values.reduce(0, +) / Double(values.count)))
            }
            let qualityValues = query.representation.samples.compactMap(\ .quality)
            let quality = qualityValues.isEmpty ? nil : qualityValues.reduce(0, +) / Double(qualityValues.count)
            queryObservations.append(LabeledDistance(
                expectedSamePerson: true, distance: 0,
                cleanSpeechSeconds: query.representation.cleanSpeechSeconds,
                quality: quality
            ))
            for (participantID, distance) in perParticipant {
                distances.append(LabeledDistance(
                    expectedSamePerson: participantID == query.participantID,
                    distance: distance, cleanSpeechSeconds: query.representation.cleanSpeechSeconds,
                    quality: quality
                ))
            }
            if let expected = perParticipant.first(where: { $0.0 == query.participantID })?.1,
               let runnerUp = perParticipant.filter({ $0.0 != query.participantID }).map(\ .1).min() {
                margins.append(runnerUp - expected)
            }
        }

        var warnings = rejected.sorted().map { "rejected sample ID: \($0)" }
        if records.count < samples.count { warnings.append("insufficient extracted cohort after rejected samples") }
        let same = distances.filter(\ .expectedSamePerson)
        let different = distances.filter { !$0.expectedSamePerson }
        if same.isEmpty { warnings.append("insufficient same-person cohort") }
        if different.isEmpty { warnings.append("insufficient different-person cohort") }

        let report = CalibrationReport(
            fingerprint: fingerprint,
            cohort: .init(
                participantCount: Set(records.map(\ .participantID)).count,
                sessionCount: Set(records.map { "\($0.participantID)\u{1f}\($0.sessionID)" }).count,
                acceptedSampleCount: records.count, rejectedSampleCount: rejected.count
            ),
            samePerson: .init(same.map(\ .distance)),
            differentPerson: .init(different.map(\ .distance)),
            durationBins: CalibrationMetrics.durationBins(queryObservations, boundaries: [2, 5, 10]),
            qualityBins: CalibrationMetrics.qualityBins(queryObservations, boundaries: [0.5, 0.75, 0.9]),
            thresholdMetrics: CalibrationMetrics.evaluate(distances, thresholds: stride(from: 0.05, through: 0.5, by: 0.05).map { $0 }),
            runnerUpMargins: .init(margins), warnings: warnings.sorted()
        )
        records.removeAll(keepingCapacity: false)
        distances.removeAll(keepingCapacity: false)
        queryObservations.removeAll(keepingCapacity: false)
        margins.removeAll(keepingCapacity: false)
        return report
    }
}

public enum CalibrationRunnerError: Error, Equatable, Sendable, CustomStringConvertible {
    case noUsableSamples
    public var description: String { "no usable calibration samples" }
}

private struct Record: Sendable {
    let sampleID: String
    let participantID: String
    let sessionID: String
    let representation: SpeakerRepresentation
}
