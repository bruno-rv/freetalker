import Foundation
import Testing
@testable import FreeTalker

@Suite struct LastCaptureDebugArtifactWriterTests {
    @Test func canonicalPublishIsIndependentAndPreservesSamples() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let samples: [Float] = [-0.75, -0.1, 0, 0.25, 0.9]
        let canonical = fixture.url("canonical.wav")
        let destination = fixture.url("last-dictation.wav")
        try Self.float32WAV(samples).write(to: canonical)

        try LastCaptureDebugArtifactWriter.publish(
            durableSource: canonical,
            samples: [0.5],
            destination: destination
        )

        let published = try Data(contentsOf: destination)
        #expect(try Self.codec.decode(published, path: destination.path) == samples)

        var changed = published
        changed[44] ^= 0xff
        try changed.write(to: destination)
        #expect(try Self.codec.decode(canonical) == samples)
    }

    @Test func canonicalPublishReplacesDestinationWithoutTemporaryResidue() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let canonical = fixture.url("canonical.wav")
        let destination = fixture.url("last-dictation.wav")
        let samples: [Float] = [0.125, -0.5]
        try Self.float32WAV(samples).write(to: canonical)
        try Data("old artifact".utf8).write(to: destination)

        try LastCaptureDebugArtifactWriter.publish(
            durableSource: canonical,
            samples: [0.75],
            destination: destination
        )

        #expect(try Self.codec.decode(destination) == samples)
        #expect(try fixture.temporaryArtifacts(for: destination).isEmpty)
    }

    @Test func publishedArtifactSurvivesCanonicalSourceDeletion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let canonical = fixture.url("canonical.wav")
        let destination = fixture.url("last-dictation.wav")
        let samples: [Float] = [0.4, -0.2, 0.1]
        try Self.float32WAV(samples).write(to: canonical)

        try LastCaptureDebugArtifactWriter.publish(
            durableSource: canonical,
            samples: [],
            destination: destination
        )
        try FileManager.default.removeItem(at: canonical)

        #expect(try Self.codec.decode(destination) == samples)
    }

    @Test func missingCanonicalSourceFallsBackToPCM16() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let destination = fixture.url("last-dictation.wav")
        let fallbackSamples: [Float] = [-1, -0.25, 0, 0.5, 1]

        try LastCaptureDebugArtifactWriter.publish(
            durableSource: fixture.url("missing.wav"),
            samples: fallbackSamples,
            destination: destination
        )

        #expect(try Data(contentsOf: destination) == WAVEncoder.encode(
            samples: fallbackSamples,
            sampleRate: 16_000
        ))
        #expect(try fixture.temporaryArtifacts(for: destination).isEmpty)
    }

    @Test func failedPublishPreservesExistingArtifact() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let destination = fixture.url("last-dictation.wav")
        let oldArtifact = Data("preserve me".utf8)
        try oldArtifact.write(to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: fixture.directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.directory.path
            )
        }

        #expect(throws: (any Error).self) {
            try LastCaptureDebugArtifactWriter.publish(
                durableSource: fixture.url("missing.wav"),
                samples: [0.5],
                destination: destination
            )
        }

        #expect(try Data(contentsOf: destination) == oldArtifact)
        #expect(try fixture.temporaryArtifacts(for: destination).isEmpty)
    }

    private static func float32WAV(_ samples: [Float]) -> Data {
        let payloadSize = samples.count * MemoryLayout<Float>.size
        var data = Data()
        func appendASCII(_ value: String) { data.append(contentsOf: value.utf8) }
        func appendInteger<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        appendASCII("RIFF")
        appendInteger(UInt32(36 + payloadSize))
        appendASCII("WAVEfmt ")
        appendInteger(UInt32(16))
        appendInteger(UInt16(3))
        appendInteger(UInt16(1))
        appendInteger(UInt32(16_000))
        appendInteger(UInt32(64_000))
        appendInteger(UInt16(4))
        appendInteger(UInt16(32))
        appendASCII("data")
        appendInteger(UInt32(payloadSize))
        for sample in samples { appendInteger(sample.bitPattern) }
        return data
    }

    private static var codec: CaptureSegmentCodec {
        CaptureSegmentCodec(fileSystem: LocalJournalFileSystem())
    }
}

private struct Fixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LastCaptureDebugArtifactWriterTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func temporaryArtifacts(for destination: URL) throws -> [String] {
        let prefix = ".\(destination.lastPathComponent)."
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            $0.hasPrefix(prefix) && $0.hasSuffix(".tmp")
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
