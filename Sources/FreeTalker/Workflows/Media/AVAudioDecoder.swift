@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import Darwin

struct AVAudioDecoder: MediaAudioDecoding {
    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    func decode(
        source: URL,
        destination: URL,
        progress: @escaping @Sendable (Double) -> Void,
        cancellation: CancellationToken
    ) async throws {
        let descriptorDestination = destination.path.hasPrefix("/dev/fd/")
        let partial = destination.appendingPathExtension("partial")
        let files = FileManager.default
        let outputDescriptor: Int32
        if descriptorDestination, let existing = Int32(destination.lastPathComponent) {
            outputDescriptor = dup(existing)
        } else {
            try? files.removeItem(at: partial)
            outputDescriptor = open(partial.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard outputDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(outputDescriptor); if !descriptorDestination { try? files.removeItem(at: partial) } }
        let writer = try PCMWAVFileWriter(descriptor: outputDescriptor)

        try cancellation.checkCancellation()
        progress(0)

        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw MediaImportError.noAudioTrack }
        let duration = try await asset.load(.duration)
        let durationSeconds = duration.seconds.isFinite ? max(duration.seconds, 0) : 0

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaImportError.decodeFailed("AVFoundation rejected the audio track") }
        reader.add(output)

        guard reader.startReading() else {
            throw MediaImportError.decodeFailed(reader.error?.localizedDescription ?? "reader could not start")
        }

        do {
            var converter: AVAudioConverter?
            while let sample = output.copyNextSampleBuffer() {
                try cancellation.checkCancellation()
                try autoreleasepool {
                    let sourceBuffer = try Self.pcmBuffer(from: sample)
                    if converter == nil {
                        converter = AVAudioConverter(from: sourceBuffer.format, to: Self.outputFormat)
                    }
                    guard let converter else { throw MediaImportError.decodeFailed("audio converter could not be created") }
                    _ = try Self.convert(sourceBuffer, with: converter, writingTo: writer)
                }
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if durationSeconds > 0, timestamp.isFinite {
                    progress(min(max(timestamp / durationSeconds, 0), 0.999))
                }
            }

            try cancellation.checkCancellation()
            guard reader.status == .completed else {
                throw MediaImportError.decodeFailed(reader.error?.localizedDescription ?? "reader stopped unexpectedly")
            }
            guard let converter else { throw MediaImportError.decodeFailed("audio track contained no decodable samples") }
            try Self.drain(converter, writingTo: writer, cancellation: cancellation)
            try writer.finish()
            if !descriptorDestination {
                if files.fileExists(atPath: destination.path) {
                    _ = try files.replaceItemAt(destination, withItemAt: partial)
                } else {
                    try files.moveItem(at: partial, to: destination)
                }
            }
            progress(1)
        } catch {
            reader.cancelReading()
            throw error
        }
    }

    private static func pcmBuffer(from sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else {
            throw MediaImportError.decodeFailed("audio sample format is unavailable")
        }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw MediaImportError.decodeFailed("audio buffer allocation failed")
        }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { throw MediaImportError.decodeFailed("audio sample copy failed (\(status))") }
        return buffer
    }

    @discardableResult
    private static func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter, writingTo file: PCMWAVFileWriter) throws -> AVAudioConverterOutputStatus {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw MediaImportError.decodeFailed("converted audio buffer allocation failed")
        }
        let state = ConverterInputState()
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            guard !state.supplied else { inputStatus.pointee = .noDataNow; return nil }
            state.supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard status != .error else { throw MediaImportError.decodeFailed("audio conversion failed") }
        if converted.frameLength > 0 { try file.write(converted) }
        return status
    }

    private static func drain(_ converter: AVAudioConverter, writingTo file: PCMWAVFileWriter, cancellation: CancellationToken) throws {
        while true {
            try cancellation.checkCancellation()
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else {
                throw MediaImportError.decodeFailed("converted audio buffer allocation failed")
            }
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let conversionError { throw conversionError }
            guard status != .error else { throw MediaImportError.decodeFailed("audio conversion drain failed") }
            if converted.frameLength > 0 { try file.write(converted) }
            if status == .endOfStream { return }
        }
    }
}

private final class ConverterInputState: @unchecked Sendable {
    var supplied = false
}
