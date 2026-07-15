import CryptoKit
import Foundation

enum CaptureJournalError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidAudioFormat(sampleRate: Double, channelCount: Int)
    case invalidWAV(String)
    case invalidOrdinal(expected: Int, actual: Int)
    case invalidSampleCount(String)
    case hashMismatch(String)
    case captureMismatch
    case queueOverflow(maximumFrames: Int)
    case failed(String)
}

struct CaptureSegmentCodec: Sendable {
    static let sampleRate = 16_000
    static let channelCount = 1
    static let bitsPerSample = 32
    static let headerSize = 44

    let fileSystem: any JournalFileSystem

    func encode(_ samples: [Float]) -> Data {
        let payloadSize = samples.count * MemoryLayout<Float>.size
        var data = Data(capacity: Self.headerSize + payloadSize)
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36 + payloadSize))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(3)) // IEEE Float
        data.appendLittleEndian(UInt16(Self.channelCount))
        data.appendLittleEndian(UInt32(Self.sampleRate))
        data.appendLittleEndian(UInt32(Self.sampleRate * MemoryLayout<Float>.size))
        data.appendLittleEndian(UInt16(MemoryLayout<Float>.size))
        data.appendLittleEndian(UInt16(Self.bitsPerSample))
        data.appendASCII("data")
        data.appendLittleEndian(UInt32(payloadSize))
        for sample in samples {
            data.appendLittleEndian(sample.bitPattern)
        }
        return data
    }

    func decode(_ url: URL) throws -> [Float] {
        try decode(fileSystem.read(url), path: url.path)
    }

    func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func hashFile(_ url: URL) throws -> String {
        hash(try fileSystem.read(url))
    }

    func validate(_ segment: CaptureSegment) throws -> [Float] {
        guard segment.url.deletingPathExtension().lastPathComponent
            == String(format: "segment-%08d", segment.ordinal) else {
            throw CaptureJournalError.invalidOrdinal(
                expected: segment.ordinal,
                actual: Self.ordinal(from: segment.url) ?? -1
            )
        }
        let data = try fileSystem.read(segment.url)
        guard hash(data) == segment.contentHash else {
            throw CaptureJournalError.hashMismatch(segment.url.path)
        }
        let samples = try decode(data, path: segment.url.path)
        guard samples.count == segment.sampleCount else {
            throw CaptureJournalError.invalidSampleCount(segment.url.path)
        }
        return samples
    }

    func assemble(
        segments: [CaptureSegment], canonicalURL: URL
    ) throws -> (sampleCount: Int, contentHash: String) {
        var samples: [Float] = []
        var captureID: UUID?
        for (expectedOrdinal, segment) in segments.enumerated() {
            guard segment.ordinal == expectedOrdinal else {
                throw CaptureJournalError.invalidOrdinal(
                    expected: expectedOrdinal, actual: segment.ordinal
                )
            }
            if let captureID, captureID != segment.captureID {
                throw CaptureJournalError.captureMismatch
            }
            captureID = segment.captureID
            samples.append(contentsOf: try validate(segment))
        }

        let data = encode(samples)
        let temporary = canonicalURL.deletingLastPathComponent().appendingPathComponent(
            ".\(canonicalURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer {
            if fileSystem.exists(temporary) { try? fileSystem.remove(temporary) }
        }
        try DurableArtifactWriter(fileSystem: fileSystem).commit(
            data, temporary: temporary, destination: canonicalURL
        )
        return (samples.count, hash(data))
    }

    private func decode(_ data: Data, path: String) throws -> [Float] {
        guard data.count >= Self.headerSize,
              data.ascii(at: 0, count: 4) == "RIFF",
              data.ascii(at: 8, count: 4) == "WAVE",
              data.ascii(at: 12, count: 4) == "fmt ",
              data.littleEndianUInt32(at: 16) == 16,
              data.littleEndianUInt16(at: 20) == 3,
              data.littleEndianUInt16(at: 22) == UInt16(Self.channelCount),
              data.littleEndianUInt32(at: 24) == UInt32(Self.sampleRate),
              data.littleEndianUInt32(at: 28) == UInt32(Self.sampleRate * 4),
              data.littleEndianUInt16(at: 32) == 4,
              data.littleEndianUInt16(at: 34) == UInt16(Self.bitsPerSample),
              data.ascii(at: 36, count: 4) == "data",
              let riffSize = data.littleEndianUInt32(at: 4),
              let payloadSize = data.littleEndianUInt32(at: 40),
              Int(riffSize) + 8 == data.count,
              Int(payloadSize) + Self.headerSize == data.count,
              payloadSize.isMultiple(of: 4) else {
            throw CaptureJournalError.invalidWAV(path)
        }

        return stride(from: Self.headerSize, to: data.count, by: 4).map {
            Float(bitPattern: data.littleEndianUInt32(at: $0)!)
        }
    }

    static func ordinal(from url: URL) -> Int? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("segment-") else { return nil }
        return Int(stem.dropFirst("segment-".count))
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func ascii(at offset: Int, count: Int) -> String? {
        guard offset >= 0, count >= 0, offset + count <= self.count else { return nil }
        return String(data: self[offset..<(offset + count)], encoding: .ascii)
    }

    func littleEndianUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func littleEndianUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
