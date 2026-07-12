import Darwin
import Foundation
import Testing
import VoiceProfileCore
import VoiceProfileFluidAudio
@testable import VoiceProfileCalibration

@Suite("Calibration runner")
struct CalibrationRunnerTests {
    @Test func invalidManifestFailsBeforeExtractorRuns() async throws {
        let fixture = try RunnerFixture()
        defer { fixture.remove() }
        let counter = LockedCounter()
        let invalid = CalibrationManifest(version: 2, samples: fixture.manifest.samples)
        await #expect(throws: CalibrationManifestError.unsupportedVersion(2)) {
            _ = try await CalibrationRunner { _ in
                counter.increment()
                throw FixtureError.rejected
            }.run(manifest: invalid)
        }
        #expect(counter.value == 0)
    }

    @Test func producesPrivateAggregateDeterministicReportsFromShuffledInput() async throws {
        let fixture = try RunnerFixture()
        defer { fixture.remove() }
        let extractor = fixture.extractor
        let first = try await CalibrationRunner(extract: extractor).run(manifest: fixture.manifest)
        let shuffled = CalibrationManifest(version: 1, samples: fixture.manifest.samples.reversed())
        let second = try await CalibrationRunner(extract: extractor).run(manifest: shuffled)
        let firstJSON = try first.jsonData()
        let secondJSON = try second.jsonData()
        #expect(firstJSON == secondJSON)

        let json = String(decoding: firstJSON, as: UTF8.self)
        let markdown = first.markdown()
        for report in [json, markdown] {
            #expect(report.contains("model-id"))
            #expect(report.contains("samePerson"))
            #expect(report.contains("differentPerson"))
            #expect(report.contains("durationBins"))
            #expect(report.contains("qualityBins"))
            #expect(report.contains("thresholdMetrics"))
            #expect(report.contains("runnerUpMargins"))
            for secret in [fixture.root.path, "serial-secret", "source-person-name", "0.12345679"] {
                #expect(!report.contains(secret))
            }
        }
        #expect(first.cohort.participantCount == 2)
        #expect(first.cohort.sessionCount == 4)
        #expect(!first.samePerson.quantiles.isEmpty)
        #expect(!first.differentPerson.quantiles.isEmpty)
        #expect(!first.thresholdMetrics.isEmpty)
    }

    @Test func reportsRejectedSampleIDsAndInsufficientExtractedCohortsWithoutPaths() async throws {
        let fixture = try RunnerFixture()
        defer { fixture.remove() }
        let rejectedID = fixture.manifest.samples[0].sampleID
        let rejectedPath = fixture.manifest.samples[0].mediaPath
        let report = try await CalibrationRunner { url in
            if url.path == rejectedPath { throw FixtureError.rejected }
            return try await fixture.extractor(url)
        }.run(manifest: fixture.manifest)
        let output = String(decoding: try report.jsonData(), as: UTF8.self) + report.markdown()
        #expect(output.contains(rejectedID))
        #expect(output.contains("insufficient"))
        #expect(!output.contains(rejectedPath))
    }

    @Test func secureWriterUsesPrivateModesRefusesSymlinksAndDoesNotClobber() throws {
        let fixture = try RunnerFixture()
        defer { fixture.remove() }
        let output = fixture.root.appendingPathComponent("reports")
        let report = CalibrationReport(
            fingerprint: .init(
                provider: "test", modelID: "test", modelRevision: "test",
                preprocessingRevision: "test", dimension: 256
            ),
            cohort: .init(
                participantCount: 0, sessionCount: 0,
                acceptedSampleCount: 0, rejectedSampleCount: 0
            ),
            samePerson: .init([]), differentPerson: .init([]),
            durationBins: [], qualityBins: [], thresholdMetrics: [],
            runnerUpMargins: .init([]), warnings: []
        )
        try CalibrationReportWriter.write(report, to: output)
        #expect(mode(output) == 0o700)
        #expect(mode(output.appendingPathComponent("calibration-report.json")) == 0o600)
        #expect(mode(output.appendingPathComponent("calibration-report.md")) == 0o600)
        #expect(throws: CalibrationReportWriteError.outputExists) {
            try CalibrationReportWriter.write(report, to: output)
        }

        let symlink = fixture.root.appendingPathComponent("linked-reports")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.root)
        #expect(throws: CalibrationReportWriteError.unsafeOutput) {
            try CalibrationReportWriter.write(report, to: symlink)
        }
    }
}

private enum FixtureError: Error { case rejected }

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private func mode(_ url: URL) -> mode_t {
    var value = stat()
    _ = lstat(url.path, &value)
    return value.st_mode & 0o777
}

private final class RunnerFixture: @unchecked Sendable {
    let root: URL
    let manifest: CalibrationManifest
    private let results: [String: OfflineVoiceRepresentationResult]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let fingerprint = EmbeddingModelFingerprint(
            provider: "provider", modelID: "model-id", modelRevision: "revision",
            preprocessingRevision: "preprocessing", dimension: 256
        )
        var samples: [CalibrationSample] = []
        var mapped: [String: OfflineVoiceRepresentationResult] = [:]
        for participant in 1...2 {
            for session in 1...2 {
                let id = "sample-\(participant)-\(session)"
                let url = root.appendingPathComponent("source-person-name-\(id).wav")
                try Data().write(to: url)
                samples.append(CalibrationSample(
                    sampleID: id, participantID: "participant-\(participant)", sessionID: "session-\(participant)-\(session)",
                    mediaPath: url.path, microphone: "serial-secret", environment: "private-home",
                    expectedSpeakerID: "expected", consentConfirmed: true
                ))
                var raw = Array(repeating: Float(0), count: 256)
                raw[participant - 1] = session == 1 ? 1 : 0.99
                raw[participant + 1] = session == 1 ? 0 : 0.1
                raw[42] = 0.12345679
                let embedding = try VoiceEmbedding(validating: raw)
                let representation = SpeakerRepresentation(
                    speakerID: "expected",
                    samples: [.init(embedding: embedding, start: 0, end: Double(session + 1), quality: 0.8)],
                    cleanSpeechSeconds: Double(session + 1)
                )
                mapped[url.path] = OfflineVoiceRepresentationResult(
                    turns: [], speakers: [representation], fingerprint: fingerprint
                )
            }
        }
        manifest = CalibrationManifest(version: 1, samples: samples)
        results = mapped
    }

    var extractor: CalibrationRunner.Extract {
        { [results] url in
            guard let result = results[url.path] else { throw FixtureError.rejected }
            return result
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
