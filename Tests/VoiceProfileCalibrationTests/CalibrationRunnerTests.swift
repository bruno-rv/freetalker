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

    @Test func validatedInputKeepsOriginalInodeWhenPathIsReplacedBySymlink() async throws {
        let fixture = try RunnerFixture()
        defer { fixture.remove() }
        let inputs = try fixture.manifest.validatedInputs()
        let original = URL(fileURLWithPath: fixture.manifest.samples[0].mediaPath)
        let sourceDirectory = original.deletingLastPathComponent()
        let moved = fixture.root.appendingPathComponent("moved-original", isDirectory: true)
        try FileManager.default.moveItem(at: sourceDirectory, to: moved)
        let replacement = fixture.root.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: replacement.appendingPathComponent(original.lastPathComponent))
        try FileManager.default.createSymbolicLink(at: sourceDirectory, withDestinationURL: replacement)
        let reads = LockedStrings()

        _ = try await CalibrationRunner { stableURL in
            reads.append(String(decoding: try Data(contentsOf: stableURL), as: UTF8.self))
            return fixture.uniformResult
        }.run(validatedInputs: inputs)

        #expect(reads.values.contains("original-sample-1-1"))
        #expect(!reads.values.contains("replacement"))
    }

    @Test func mutationAfterValidationRejectsSampleWithIDOnlyWarning() async throws {
        let fixture = try RunnerFixture()
        defer { fixture.remove() }
        let inputs = try fixture.manifest.validatedInputs()
        let changed = fixture.manifest.samples[0]
        try Data("truncated".utf8).write(to: URL(fileURLWithPath: changed.mediaPath))
        let report = try await CalibrationRunner { _ in fixture.uniformResult }
            .run(validatedInputs: inputs)
        let output = String(decoding: try report.jsonData(), as: UTF8.self) + report.markdown()
        #expect(output.contains(changed.sampleID))
        #expect(!output.contains(changed.mediaPath))
        #expect(report.cohort.rejectedSampleCount == 1)
    }

    @Test func mutationDuringExtractionFailsPostProcessingIdentityCheck() async throws {
        let fixture = try ExactRunnerFixture(participantCount: 2)
        defer { fixture.remove() }
        let inputs = try fixture.manifest.validatedInputs()
        let changed = fixture.manifest.samples[0]
        let didMutate = LockedCounter()
        let report = try await CalibrationRunner { url in
            let result = try fixture.result(reading: url)
            if didMutate.value == 0 {
                didMutate.increment()
                try Data("changed-during-extraction".utf8).write(
                    to: URL(fileURLWithPath: changed.mediaPath)
                )
            }
            return result
        }.run(validatedInputs: inputs)
        #expect(report.cohort.rejectedSampleCount == 1)
        #expect(report.warnings.contains { $0.contains(changed.sampleID) })
    }

    @Test func exactPairLabelsCrossSessionDistancesAndRunnerUpMargins() async throws {
        let fixture = try ExactRunnerFixture(participantCount: 2, crossSessionContrast: true)
        defer { fixture.remove() }
        let report = try await CalibrationRunner(extract: fixture.extractor).run(manifest: fixture.manifest)
        #expect(report.samePerson.count == 4)
        #expect(report.samePerson.quantiles["p50"] == 0.5)
        #expect(report.differentPerson.count == 4)
        #expect(report.differentPerson.quantiles.values.allSatisfy { $0 == 1 })
        #expect(report.runnerUpMargins.count == 4)
        #expect(report.runnerUpMargins.quantiles["p05"] == 0)
        #expect(report.runnerUpMargins.quantiles["p50"] == 0.5)
        #expect(report.runnerUpMargins.quantiles["p95"] == 1)
    }

    @Test func queryBinsDoNotMultiplyByEnrollmentParticipantsAndSkipMissingQuality() async throws {
        let fixture = try ExactRunnerFixture(participantCount: 3, missingQualityToken: "p3s2")
        defer { fixture.remove() }
        let report = try await CalibrationRunner(extract: fixture.extractor).run(manifest: fixture.manifest)
        #expect(report.cohort.acceptedSampleCount == 6)
        #expect(report.samePerson.count == 6)
        #expect(report.differentPerson.count == 12)
        #expect(report.durationBins.reduce(0) { $0 + $1.count } == 6)
        #expect(report.qualityBins.reduce(0) { $0 + $1.count } == 5)
    }

    @Test func threeSessionCalibrationUsesSharedMinimumOfPrototypeMeansDeterministically() async throws {
        let fixture = try ExactRunnerFixture(
            participantCount: 2, sessionCount: 3, multiPrototypeContrast: true
        )
        defer { fixture.remove() }
        let report = try await CalibrationRunner(extract: fixture.extractor).run(manifest: fixture.manifest)
        let expectedSame = (2 - 2 * cos(Double.pi / 4)) / 3
        let expectedMargin = 1 - expectedSame
        #expect(report.samePerson.count == 6)
        #expect(abs(report.samePerson.quantiles["p95"]! - expectedSame) < 0.000_001)
        #expect(report.differentPerson.count == 6)
        #expect(report.differentPerson.quantiles.values.allSatisfy { abs($0 - 1) < 0.000_001 })
        #expect(report.runnerUpMargins.count == 6)
        #expect(abs(report.runnerUpMargins.quantiles["p05"]! - expectedMargin) < 0.000_001)
        let below = report.thresholdMetrics.first { abs($0.threshold - 0.15) < 0.000_001 }!
        #expect(below.trueMatchCount == 3)
        #expect(below.missedMatchCount == 3)
        let accepting = report.thresholdMetrics.first { abs($0.threshold - 0.2) < 0.000_001 }!
        #expect(accepting.trueMatchCount == 6)
        #expect(accepting.missedMatchCount == 0)
        #expect(accepting.falseMatchCount == 0)
        #expect(accepting.trueRejectCount == 6)

        let reversed = CalibrationManifest(version: 1, samples: fixture.manifest.samples.reversed())
        let repeated = try await CalibrationRunner(extract: fixture.extractor).run(manifest: reversed)
        #expect(try report.jsonData() == repeated.jsonData())
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
        #expect(first.samePerson.count == 4)
        #expect(first.differentPerson.count == 4)
        #expect(first.runnerUpMargins.count == 4)
        #expect(first.durationBins.reduce(0) { $0 + $1.count } == 4)
        #expect(first.qualityBins.reduce(0) { $0 + $1.count } == 4)
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
            let contents = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            if contents == "original-sample-1-1" { throw FixtureError.rejected }
            return fixture.uniformResult
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

    @Test func reportPublishIsAllOrNothingAndFsyncsBeforeExclusiveRename() throws {
        let fixture = try RunnerFixture()
        defer { fixture.remove() }
        let output = fixture.root.appendingPathComponent("atomic-reports")
        let events = LockedStrings()
        let report = fixture.emptyReport
        try CalibrationReportWriter.write(
            report, to: output,
            hooks: .init(record: { events.append($0) })
        )
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("calibration-report.json").path))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("calibration-report.md").path))
        #expect(events.values == ["fsync:file:json", "fsync:file:markdown", "fsync:staging", "publish", "fsync:parent"])

        let failed = fixture.root.appendingPathComponent("failed-reports")
        #expect(throws: CalibrationReportWriteError.writeFailed) {
            try CalibrationReportWriter.write(
                report, to: failed,
                hooks: .init(beforeWrite: { name in
                    if name == "calibration-report.md" { throw CalibrationReportWriteError.writeFailed }
                })
            )
        }
        #expect(!FileManager.default.fileExists(atPath: failed.path))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        #expect(!siblings.contains { $0.hasPrefix(".voice-calibration-") })
    }

    @Test func reportWriterRejectsSymlinkAncestor() throws {
        let fixture = try RunnerFixture()
        defer { fixture.remove() }
        let real = fixture.root.appendingPathComponent("real-parent")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let linked = fixture.root.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        #expect(throws: CalibrationReportWriteError.unsafeOutput) {
            try CalibrationReportWriter.write(
                fixture.emptyReport,
                to: linked.appendingPathComponent("reports")
            )
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

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
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
    let uniformResult: OfflineVoiceRepresentationResult

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
                let directory = root.appendingPathComponent("source-\(id)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let url = directory.appendingPathComponent("source-person-name.wav")
                try Data("original-sample-\(participant)-\(session)".utf8).write(to: url)
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
        uniformResult = mapped.values.first!
    }

    var extractor: CalibrationRunner.Extract {
        { [results] url in
            let contents = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            let suffix = contents.replacingOccurrences(of: "original-sample-", with: "")
            let components = suffix.split(separator: "-")
            guard components.count == 2 else { throw FixtureError.rejected }
            let key = results.keys.first { $0.contains("sample-\(components[0])-\(components[1])") }
            guard let key, let result = results[key] else { throw FixtureError.rejected }
            return result
        }
    }


    var emptyReport: CalibrationReport {
        CalibrationReport(
            fingerprint: uniformResult.fingerprint,
            cohort: .init(participantCount: 0, sessionCount: 0, acceptedSampleCount: 0, rejectedSampleCount: 0),
            samePerson: .init([]), differentPerson: .init([]), durationBins: [], qualityBins: [],
            thresholdMetrics: [], runnerUpMargins: .init([]), warnings: []
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class ExactRunnerFixture: @unchecked Sendable {
    let root: URL
    let manifest: CalibrationManifest
    private let results: [String: OfflineVoiceRepresentationResult]

    init(
        participantCount: Int,
        sessionCount: Int = 2,
        crossSessionContrast: Bool = false,
        missingQualityToken: String? = nil,
        multiPrototypeContrast: Bool = false
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let fingerprint = EmbeddingModelFingerprint(
            provider: "exact", modelID: "exact", modelRevision: "exact",
            preprocessingRevision: "exact", dimension: 256
        )
        var samples: [CalibrationSample] = []
        var mapped: [String: OfflineVoiceRepresentationResult] = [:]
        for participant in 1...participantCount {
            for session in 1...sessionCount {
                let token = "p\(participant)s\(session)"
                let url = root.appendingPathComponent("\(token).wav")
                try Data(token.utf8).write(to: url)
                samples.append(.init(
                    sampleID: token, participantID: "p\(participant)", sessionID: "s\(session)",
                    mediaPath: url.path, microphone: "m", environment: "e",
                    expectedSpeakerID: "expected", consentConfirmed: true
                ))
                let embeddings: [VoiceEmbedding]
                if multiPrototypeContrast && participant == 1 {
                    embeddings = try [
                        Self.unitVector(0), Self.unitVector(1),
                        Self.angledVector(Double.pi / 4)
                    ]
                } else {
                    var raw = Array(repeating: Float(0), count: 256)
                    let index = crossSessionContrast && participant == 1 ? session - 1 : participant + 1
                    raw[index] = 1
                    embeddings = [try VoiceEmbedding(validating: raw)]
                }
                let representation = SpeakerRepresentation(
                    speakerID: "expected",
                    samples: embeddings.enumerated().map { index, embedding in .init(
                        embedding: embedding, start: Double(index), end: Double(index + 1),
                        quality: token == missingQualityToken ? nil : 0.8
                    ) },
                    cleanSpeechSeconds: 3
                )
                mapped[token] = .init(turns: [], speakers: [representation], fingerprint: fingerprint)
            }
        }
        manifest = .init(version: 1, samples: samples)
        results = mapped
    }

    func result(reading url: URL) throws -> OfflineVoiceRepresentationResult {
        let token = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        guard let result = results[token] else { throw FixtureError.rejected }
        return result
    }

    var extractor: CalibrationRunner.Extract {
        { [self] url in try result(reading: url) }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    private static func unitVector(_ index: Int) throws -> VoiceEmbedding {
        var raw = Array(repeating: Float(0), count: 256)
        raw[index] = 1
        return try VoiceEmbedding(validating: raw)
    }

    private static func angledVector(_ angle: Double) throws -> VoiceEmbedding {
        var raw = Array(repeating: Float(0), count: 256)
        raw[0] = Float(cos(angle))
        raw[1] = Float(sin(angle))
        return try VoiceEmbedding(validating: raw)
    }
}
