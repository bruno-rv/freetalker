import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
import OSLog

final class AudioCapture {
    enum VoiceProcessingAction: Equatable {
        case keepCurrent
        case setRequested
        case replaceWithRawEngine
    }

    private static let logger = Logger(subsystem: "org.freetalker.app", category: "audio-capture")
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    // Guards `samples` and `conversionFailureCount`, which cross the tap and main threads.
    private let samplesLock = NSLock()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var isCapturing = false
    private var conversionFailureCount = 0

    private(set) var captureWarnings: [String] = []

    nonisolated static func voiceProcessingAction(
        requested: Bool,
        current: Bool,
        transitionFailed: Bool
    ) -> VoiceProcessingAction {
        guard requested != current else { return .keepCurrent }
        if transitionFailed { return .replaceWithRawEngine }
        return .setRequested
    }

    nonisolated static func captureWarnings(_ existing: [String], adding warning: String) -> [String] {
        existing + [warning]
    }

    /// Starts capturing. Throws if the mic can't be opened (e.g. permission denied).
    /// - Parameter deviceUID: CoreAudio UID of the input device to pin (AppSettings
    ///   `microphoneDeviceUID`), or nil to use the system default input.
    func start(deviceUID: String?, noiseSuppression: Bool) throws {
        samplesLock.lock()
        samples.removeAll()
        conversionFailureCount = 0
        samplesLock.unlock()
        converter = nil
        captureWarnings.removeAll()

        let input = try reconcileVoiceProcessing(requested: noiseSuppression)
        applyConfiguredInputDevice(uid: deviceUID, to: input)
        logEffectiveInputDevice(for: input)

        let inputFormat = input.outputFormat(forBus: 0)
        Self.logger.info("Negotiated input format: \(inputFormat.description, privacy: .public)")
        guard let negotiatedConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterUnavailable(inputFormat.description)
        }
        converter = negotiatedConverter

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

    func snapshot() -> [Float] {
        samplesLock.lock()
        defer { samplesLock.unlock() }
        return samples
    }

    nonisolated static func boundedSuffix(_ samples: [Float], maxSamples: Int) -> [Float] {
        Array(samples.suffix(maxSamples))
    }

    /// Thread-safe bounded copy: only the last `min(count, maxSamples)` samples, plus the total
    /// sample count. The bound is applied *inside* `samplesLock`, before any array leaves the
    /// lock — `Array(samples.suffix(maxSamples))` materializes a fresh, independently-storaged
    /// array rather than an `ArraySlice` that shares the big buffer's storage, so no returned
    /// value retains the full recording. That matters because `consume(buffer:inputFormat:)`
    /// runs on the AVAudioEngine tap thread and appends to `samples` on every buffer; if a
    /// caller-held slice referenced that storage, the next append would trigger copy-on-write of
    /// the *entire* growing buffer instead of Array's amortized-O(1) append. Used by the live
    /// preview loop so a tick's copy cost — and the COW risk on the tap thread — is bounded by
    /// the window, not by total recording length (Codex round-4 finding: the bound must apply at
    /// the copy, not by slicing an already-full-size copy after the fact). `totalCount` lets
    /// callers gate on the *whole* recording's size (e.g. the tick's <1s skip gate) without a
    /// second, separate `snapshot()` call.
    func snapshotSuffix(maxSamples: Int) -> (suffix: [Float], totalCount: Int) {
        samplesLock.lock()
        defer { samplesLock.unlock() }
        return (Self.boundedSuffix(samples, maxSamples: maxSamples), samples.count)
    }

    /// Stops capturing and returns the accumulated 16 kHz mono Float32 samples.
    func stop() -> [Float] {
        if isCapturing {
            isCapturing = false
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        samplesLock.lock()
        let capturedSamples = samples
        let failures = conversionFailureCount
        samplesLock.unlock()
        Self.logger.info("Capture stopped with \(failures) conversion failures")
        return capturedSamples
    }

    private func reconcileVoiceProcessing(requested: Bool) throws -> AVAudioInputNode {
        var input = engine.inputNode
        let current = input.isVoiceProcessingEnabled
        guard Self.voiceProcessingAction(
            requested: requested,
            current: current,
            transitionFailed: false
        ) == .setRequested else {
            Self.logger.info("Voice processing requested=\(requested) effective=\(current)")
            return input
        }

        do {
            try input.setVoiceProcessingEnabled(requested)
        } catch {
            Self.logger.error("Voice-processing transition failed: \(error.localizedDescription, privacy: .public)")
            engine.stop()
            engine = AVAudioEngine()
            Self.logger.warning("Recreated audio engine for raw-capture fallback")
            input = engine.inputNode
            if input.isVoiceProcessingEnabled {
                do {
                    try input.setVoiceProcessingEnabled(false)
                } catch {
                    Self.logger.error("Could not disable voice processing on replacement engine: \(error.localizedDescription, privacy: .public)")
                    throw CaptureError.rawFallbackUnavailable(error.localizedDescription)
                }
            }
            guard !input.isVoiceProcessingEnabled else {
                throw CaptureError.rawFallbackUnavailable("voice processing remained enabled")
            }
            recordWarning("Voice processing could not be configured — using raw microphone audio")
        }

        Self.logger.info("Voice processing requested=\(requested) effective=\(input.isVoiceProcessingEnabled)")
        return input
    }

    /// Pins the engine's input to the CoreAudio device identified by `uid`, if any. Must run
    /// before reading `input.outputFormat`/installing the tap: switching devices can change the
    /// native sample rate/channel count. No-op (system default stays in effect) when `uid` is
    /// nil. When `uid` is set but doesn't resolve to a connected device, or the AudioUnit
    /// rejects it, leaves the system default in effect and records a capture warning.
    private func applyConfiguredInputDevice(uid: String?, to input: AVAudioInputNode) {
        guard let uid else { return }
        guard let deviceID = AudioInputDevices.resolveID(forUID: uid) else {
            recordWarning("Configured microphone not found — using system default")
            return
        }
        guard let audioUnit = input.audioUnit else {
            recordWarning("Could not select configured microphone — using system default")
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
            recordWarning("Could not select configured microphone — using system default")
        }
    }

    private func recordWarning(_ warning: String) {
        captureWarnings = Self.captureWarnings(captureWarnings, adding: warning)
    }

    private func logEffectiveInputDevice(for input: AVAudioInputNode) {
        guard let audioUnit = input.audioUnit else {
            Self.logger.error("Effective input device unknown: input audio unit unavailable")
            return
        }
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        guard status == noErr else {
            Self.logger.error("Effective input device query failed with status \(status)")
            return
        }
        Self.logger.info("Effective input device ID: \(deviceID)")
    }

    private func consume(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard let converter else {
            recordConversionFailure()
            return
        }
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            recordConversionFailure()
            return
        }

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

        guard status != .error, error == nil else {
            recordConversionFailure()
            return
        }
        guard let channelData = outBuffer.floatChannelData else {
            recordConversionFailure()
            return
        }
        let frameCount = Int(outBuffer.frameLength)
        samplesLock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameCount))
        samplesLock.unlock()
    }

    private func recordConversionFailure() {
        samplesLock.lock()
        conversionFailureCount += 1
        samplesLock.unlock()
    }
}

private enum CaptureError: LocalizedError {
    case converterUnavailable(String)
    case rawFallbackUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .converterUnavailable(format):
            "Could not convert microphone format \(format) to 16 kHz mono audio"
        case let .rawFallbackUnavailable(reason):
            "Could not establish raw microphone capture after voice-processing failure: \(reason)"
        }
    }
}
