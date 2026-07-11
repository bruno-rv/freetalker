@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

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
        let partial = destination.appendingPathExtension("partial")
        let files = FileManager.default
        try? files.removeItem(at: partial)
        defer { try? files.removeItem(at: partial) }

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
            var writer: AVAudioFile?
            var converter: AVAudioConverter?
            while let sample = output.copyNextSampleBuffer() {
                try cancellation.checkCancellation()
                try autoreleasepool {
                    let sourceBuffer = try Self.pcmBuffer(from: sample)
                    if converter == nil {
                        converter = AVAudioConverter(from: sourceBuffer.format, to: Self.outputFormat)
                        writer = try AVAudioFile(
                            forWriting: partial,
                            settings: Self.outputFormat.settings,
                            commonFormat: .pcmFormatFloat32,
                            interleaved: false
                        )
                    }
                    guard let converter, let writer else { throw MediaImportError.decodeFailed("audio converter could not be created") }
                    try Self.convert(sourceBuffer, with: converter, writingTo: writer)
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
            guard writer != nil else { throw MediaImportError.decodeFailed("audio track contained no decodable samples") }
            if files.fileExists(atPath: destination.path) {
                _ = try files.replaceItemAt(destination, withItemAt: partial)
            } else {
                try files.moveItem(at: partial, to: destination)
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

    private static func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter, writingTo file: AVAudioFile) throws {
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
        if converted.frameLength > 0 { try file.write(from: converted) }
    }
}

private final class ConverterInputState: @unchecked Sendable {
    var supplied = false
}
