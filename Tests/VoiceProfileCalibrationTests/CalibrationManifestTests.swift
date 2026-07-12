import Foundation
import Testing
@testable import VoiceProfileCalibration

@Suite("Calibration manifest")
struct CalibrationManifestTests {
    @Test func acceptsVersionedConsentedCrossSessionCohort() throws {
        let fixture = try ManifestFixture()
        defer { fixture.remove() }
        let manifest = fixture.manifest()
        #expect(try manifest.validatedSamples().count == 4)
    }

    @Test(arguments: [0, 2])
    func rejectsUnsupportedVersions(_ version: Int) throws {
        let fixture = try ManifestFixture()
        defer { fixture.remove() }
        #expect(throws: CalibrationManifestError.unsupportedVersion(version)) {
            try fixture.manifest(version: version).validatedSamples()
        }
    }

    @Test func rejectsDuplicateAndBlankPseudonymousIdentifiersWithoutLeakingPaths() throws {
        let fixture = try ManifestFixture()
        defer { fixture.remove() }
        var samples = fixture.samples
        samples[1] = sample(from: samples[1], sampleID: samples[0].sampleID)
        assertPrivateFailure(CalibrationManifest(version: 1, samples: samples), secret: fixture.root.path)

        samples = fixture.samples
        samples[0] = sample(from: samples[0], participantID: " \t")
        assertPrivateFailure(CalibrationManifest(version: 1, samples: samples), secret: fixture.root.path)
    }

    @Test func rejectsRelativeMissingAndUnconsentedMediaWithoutLeakingPaths() throws {
        let fixture = try ManifestFixture()
        defer { fixture.remove() }
        for replacement in [
            sample(from: fixture.samples[0], mediaPath: "relative.wav"),
            sample(from: fixture.samples[0], mediaPath: fixture.root.appendingPathComponent("private-missing.wav").path),
            sample(from: fixture.samples[0], consentConfirmed: false)
        ] {
            var samples = fixture.samples
            samples[0] = replacement
            assertPrivateFailure(CalibrationManifest(version: 1, samples: samples), secret: replacement.mediaPath)
        }
    }

    @Test func rejectsTooFewParticipantsAndSessions() throws {
        let fixture = try ManifestFixture()
        defer { fixture.remove() }
        #expect(throws: CalibrationManifestError.insufficientParticipants) {
            try CalibrationManifest(version: 1, samples: Array(fixture.samples.prefix(2))).validatedSamples()
        }
        var samples = fixture.samples
        samples[1] = sample(from: samples[1], sessionID: samples[0].sessionID)
        #expect(throws: CalibrationManifestError.insufficientSessions(participantID: "p1")) {
            try CalibrationManifest(version: 1, samples: samples).validatedSamples()
        }
    }

    @Test func commandLineParserRejectsMissingDuplicateUnknownAndRelativeValues() throws {
        #expect(throws: CalibrationArgumentError.missingArgument("--manifest")) {
            try CalibrationArguments.parse(["--output-directory", "/tmp/out"])
        }
        #expect(throws: CalibrationArgumentError.duplicateArgument("--manifest")) {
            try CalibrationArguments.parse(["--manifest", "/tmp/a", "--manifest", "/tmp/b", "--output-directory", "/tmp/out"])
        }
        #expect(throws: CalibrationArgumentError.unknownArgument("--other")) {
            try CalibrationArguments.parse(["--other", "x", "--manifest", "/tmp/a", "--output-directory", "/tmp/out"])
        }
        #expect(throws: CalibrationArgumentError.nonAbsoluteArgument("--manifest")) {
            try CalibrationArguments.parse(["--manifest", "a.json", "--output-directory", "/tmp/out"])
        }
        let parsed = try CalibrationArguments.parse(["--manifest", "/tmp/a", "--output-directory", "/tmp/out"])
        #expect(parsed.manifestURL.path == "/tmp/a")
        #expect(parsed.outputDirectoryURL.path == "/tmp/out")
        #expect(!CalibrationArgumentError.unknownArgument("/private/source.wav").description.contains("/private"))
    }
}

private func assertPrivateFailure(_ manifest: CalibrationManifest, secret: String) {
    do {
        _ = try manifest.validatedSamples()
        Issue.record("Expected validation failure")
    } catch {
        #expect(!String(describing: error).contains(secret))
    }
}

private func sample(
    from value: CalibrationSample,
    sampleID: String? = nil,
    participantID: String? = nil,
    sessionID: String? = nil,
    mediaPath: String? = nil,
    consentConfirmed: Bool? = nil
) -> CalibrationSample {
    CalibrationSample(
        sampleID: sampleID ?? value.sampleID,
        participantID: participantID ?? value.participantID,
        sessionID: sessionID ?? value.sessionID,
        mediaPath: mediaPath ?? value.mediaPath,
        microphone: value.microphone,
        environment: value.environment,
        expectedSpeakerID: value.expectedSpeakerID,
        consentConfirmed: consentConfirmed ?? value.consentConfirmed
    )
}

private final class ManifestFixture {
    let root: URL
    let samples: [CalibrationSample]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        var values: [CalibrationSample] = []
        for participant in 1...2 {
            for session in 1...2 {
                let id = "s\(participant)\(session)"
                let file = root.appendingPathComponent("secret-\(id).wav")
                try Data().write(to: file)
                values.append(CalibrationSample(
                    sampleID: id, participantID: "p\(participant)", sessionID: "session\(session)",
                    mediaPath: file.path, microphone: "serial-secret", environment: "office",
                    expectedSpeakerID: "speaker", consentConfirmed: true
                ))
            }
        }
        samples = values
    }

    func manifest(version: Int = 1) -> CalibrationManifest {
        CalibrationManifest(version: version, samples: samples)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
