import AVFoundation
import Darwin
import Foundation

final class PCMWAVFileWriter {
    private let descriptor: Int32
    private var dataBytes: UInt64 = 0
    private var finished = false

    init(descriptor: Int32) throws {
        self.descriptor = descriptor
        guard ftruncate(descriptor, 0) == 0 else { throw Self.posixError() }
        try Self.writeAll(descriptor, bytes: [UInt8](repeating: 0, count: 44))
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        let byteCount = UInt64(buffer.frameLength) * 4
        guard byteCount <= UInt64(Int.max), dataBytes + byteCount <= UInt64(UInt32.max) else {
            throw MediaImportError.decodeFailed("decoded WAV exceeds the 4 GB PCM WAV limit")
        }
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard let data = audioBuffer.mData, UInt64(audioBuffer.mDataByteSize) >= byteCount else {
            throw MediaImportError.decodeFailed("converted PCM buffer is incomplete")
        }
        try Self.writeAll(descriptor, pointer: data, count: Int(byteCount))
        dataBytes += byteCount
    }

    func finish() throws {
        guard !finished else { return }
        let dataSize = UInt32(dataBytes)
        var header = [UInt8](repeating: 0, count: 44)
        func ascii(_ text: String, _ offset: Int) { header.replaceSubrange(offset..<(offset + text.utf8.count), with: text.utf8) }
        func u16(_ value: UInt16, _ offset: Int) { header[offset] = UInt8(value & 0xff); header[offset + 1] = UInt8(value >> 8) }
        func u32(_ value: UInt32, _ offset: Int) { for index in 0..<4 { header[offset + index] = UInt8((value >> UInt32(index * 8)) & 0xff) } }
        ascii("RIFF", 0); u32(36 + dataSize, 4); ascii("WAVE", 8); ascii("fmt ", 12); u32(16, 16)
        u16(3, 20); u16(1, 22); u32(16_000, 24); u32(64_000, 28); u16(4, 32); u16(32, 34)
        ascii("data", 36); u32(dataSize, 40)
        try header.withUnsafeBytes { bytes in try Self.pwriteAll(descriptor, pointer: bytes.baseAddress!, count: bytes.count, offset: 0) }
        guard fsync(descriptor) == 0 else { throw Self.posixError() }
        finished = true
    }

    private static func writeAll(_ descriptor: Int32, bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { raw in try writeAll(descriptor, pointer: raw.baseAddress!, count: raw.count) }
    }

    private static func writeAll(_ descriptor: Int32, pointer: UnsafeRawPointer, count: Int) throws {
        var written = 0
        while written < count {
            let result = Darwin.write(descriptor, pointer.advanced(by: written), count - written)
            if result > 0 { written += result; continue }
            if result < 0, errno == EINTR { continue }
            throw posixError()
        }
    }

    private static func pwriteAll(_ descriptor: Int32, pointer: UnsafeRawPointer, count: Int, offset: off_t) throws {
        var written = 0
        while written < count {
            let result = Darwin.pwrite(descriptor, pointer.advanced(by: written), count - written, offset + off_t(written))
            if result > 0 { written += result; continue }
            if result < 0, errno == EINTR { continue }
            throw posixError()
        }
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
