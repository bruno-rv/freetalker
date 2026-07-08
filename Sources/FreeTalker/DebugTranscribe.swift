@preconcurrency import AVFoundation
import Foundation

// ponytail: debug harness only, not shipped in the real hot-key pipeline (that goes through
// AudioCapture's streaming tap). Lets `--transcribe <wav-path>` run a WAV file through the real
// WhisperKitEngine end-to-end from the command line for manual/CI verification. Upgrade path:
// none planned — AudioCapture's tap-based path is what ships.
enum AudioFileLoader {
    enum LoadError: Error { case bufferAllocationFailed, converterCreationFailed, conversionFailed }

    /// Reads an entire audio file and converts it to 16 kHz mono Float32 samples, matching the
    /// format WhisperKit expects (same target format as AudioCapture's live-mic path).
    static func loadSamples16kMono(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw LoadError.bufferAllocationFailed
        }
        try file.read(into: inputBuffer)

        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw LoadError.converterCreationFailed
        }
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            throw LoadError.bufferAllocationFailed
        }

        var error: NSError?
        nonisolated(unsafe) var suppliedInput = false
        let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, let channelData = outBuffer.floatChannelData else {
            throw error ?? LoadError.conversionFailed
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))
    }
}

enum DebugTranscribe {
    static func runAndExit(path: String) -> Never {
        let engine = WhisperKitEngine()
        Task {
            let statusTask = Task {
                var last = ""
                while !Task.isCancelled {
                    let current = await MainActor.run { engine.statusText }
                    if current != last {
                        FileHandle.standardError.write("[whisperkit] \(current)\n".data(using: .utf8)!)
                        last = current
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            do {
                let samples = try AudioFileLoader.loadSamples16kMono(from: URL(fileURLWithPath: path))
                FileHandle.standardError.write("[debug] loaded \(samples.count) samples from \(path)\n".data(using: .utf8)!)
                let output = try await engine.transcribe(samples: samples)
                statusTask.cancel()
                let transcript = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                print("language: \(output.language)")
                print("transcript: \(transcript)")
                exit(transcript.isEmpty ? 1 : 0)
            } catch {
                statusTask.cancel()
                FileHandle.standardError.write("[debug] error: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        dispatchMain()
    }
}
