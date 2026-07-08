import AudioToolbox
@preconcurrency import AVFoundation
import Foundation

/// Captures microphone audio while push-to-talk is held, converting to 16 kHz mono Float32
/// samples as required by WhisperKit. Batch capture only (PLAN.md: no streaming in v1).
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    // Guards `samples`: appended from the AVAudioEngine tap thread in `consume`, read from
    // `stop()` (main actor). See Round 1 Codex finding 7.
    private let samplesLock = NSLock()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var isCapturing = false

    /// Set by `start()` when `deviceUID` was configured but could not be pinned (the device
    /// is unplugged, or the AudioUnit rejected it), meaning capture fell back to the system
    /// default input. nil when no note applies. Read by the caller right after `start()`
    /// returns to surface a HUD note — see incident: closed-lid MacBook makes the system
    /// default (built-in mic) deliver pure zeros.
    private(set) var deviceFallbackNote: String?

    /// Starts capturing. Throws if the mic can't be opened (e.g. permission denied).
    /// - Parameter deviceUID: CoreAudio UID of the input device to pin (AppSettings
    ///   `microphoneDeviceUID`), or nil to use the system default input.
    func start(deviceUID: String?) throws {
        samplesLock.lock()
        samples.removeAll()
        samplesLock.unlock()
        deviceFallbackNote = nil

        let input = engine.inputNode
        applyConfiguredInputDevice(uid: deviceUID, to: input)

        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer: buffer, inputFormat: inputFormat)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Leaving the tap installed while `isCapturing` stays false would make the next
            // `start()` install a second tap on the same bus. See Round 1 Codex finding 6.
            input.removeTap(onBus: 0)
            throw error
        }
        isCapturing = true
    }

    /// Stops capturing and returns the accumulated 16 kHz mono Float32 samples.
    func stop() -> [Float] {
        if isCapturing {
            isCapturing = false
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        samplesLock.lock()
        defer { samplesLock.unlock() }
        return samples
    }

    /// Pins the engine's input to the CoreAudio device identified by `uid`, if any. Must run
    /// before reading `input.outputFormat`/installing the tap: switching devices can change the
    /// native sample rate/channel count. No-op (system default stays in effect) when `uid` is
    /// nil. When `uid` is set but doesn't resolve to a connected device, or the AudioUnit
    /// rejects it, leaves the system default in effect and records `deviceFallbackNote`.
    private func applyConfiguredInputDevice(uid: String?, to input: AVAudioInputNode) {
        guard let uid else { return }
        guard let deviceID = AudioInputDevices.resolveID(forUID: uid) else {
            deviceFallbackNote = "Configured microphone not found — using system default"
            return
        }
        guard let audioUnit = input.audioUnit else {
            deviceFallbackNote = "Could not select configured microphone — using system default"
            return
        }
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            deviceFallbackNote = "Could not select configured microphone — using system default"
        }
    }

    private func consume(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

        var error: NSError?
        // AVAudioConverter always calls this handler synchronously/serially on the calling
        // thread while `convert` runs — the `@Sendable` closure type is a formality here.
        nonisolated(unsafe) var suppliedInput = false
        let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, let channelData = outBuffer.floatChannelData else { return }
        let frameCount = Int(outBuffer.frameLength)
        samplesLock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameCount))
        samplesLock.unlock()
    }
}
