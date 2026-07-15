import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
import OSLog

enum AudioCaptureFault: Equatable, Sendable {
    case inputRoute(captureID: UUID, message: String)
    case engine(captureID: UUID, message: String)

    var captureID: UUID {
        switch self {
        case .inputRoute(let captureID, _), .engine(let captureID, _): captureID
        }
    }

    var message: String {
        switch self {
        case .inputRoute(_, let message), .engine(_, let message): message
        }
    }
}

struct MicrophoneSignalWatchdog: Sendable {
    enum Decision: Equatable, Sendable {
        case continueRecording
        case warnNoSignal
        case restartForRouteFailure(String)
    }

    static let signalFloor: Float = 1e-7

    let captureID: UUID?
    private(set) var hasObservedSignal = false
    private(set) var didRequestRestart = false
    private(set) var observationCount = 0
    private(set) var peak: Float = 0
    private(set) var rms: Float = 0
    private var warned = false
    private var silentObservationCount = 0
    private var sumSquares: Double = 0
    private var sampleCount = 0

    init(captureID: UUID? = nil) {
        self.captureID = captureID
    }

    var isSilentAttempt: Bool { !hasObservedSignal }
    var retainedSampleCount: Int { 0 }

    mutating func observe(samples: [Float], fault: AudioCaptureFault? = nil) -> Decision {
        observationCount += 1
        var localPeak: Float = 0
        var localSquares: Double = 0
        for sample in samples where sample.isFinite {
            localPeak = max(localPeak, abs(sample))
            localSquares += Double(sample) * Double(sample)
        }
        peak = max(peak, localPeak)
        sumSquares += localSquares
        sampleCount += samples.count
        rms = sampleCount == 0 ? 0 : Float((sumSquares / Double(sampleCount)).squareRoot())
        return decide(peak: localPeak, rms: samples.isEmpty ? 0 : Float((localSquares / Double(samples.count)).squareRoot()), fault: fault)
    }

    mutating func observe(peak: Float, rms: Float, fault: AudioCaptureFault?) -> Decision {
        observationCount += 1
        self.peak = max(self.peak, peak.isFinite ? max(0, peak) : 0)
        self.rms = max(self.rms, rms.isFinite ? max(0, rms) : 0)
        return decide(peak: peak, rms: rms, fault: fault)
    }

    private mutating func decide(peak: Float, rms: Float, fault: AudioCaptureFault?) -> Decision {
        if peak.isFinite, rms.isFinite,
           peak > Self.signalFloor || rms > Self.signalFloor {
            hasObservedSignal = true
            return .continueRecording
        }
        guard !hasObservedSignal else { return .continueRecording }
        silentObservationCount += 1
        if let fault,
           !didRequestRestart,
           captureID == nil || fault.captureID == captureID {
            didRequestRestart = true
            warned = true
            return .restartForRouteFailure(fault.message)
        }
        if !warned, silentObservationCount >= 3 {
            warned = true
            return .warnNoSignal
        }
        return .continueRecording
    }
}

final class AudioCapture: @unchecked Sendable {
    enum ConsumerFailureAction: Equatable { case none, escalate }
    enum CaptureRoute: Equatable {
        case voiceProcessedSystemDefault
        case rawSelectedMicrophoneSuppressionUnavailable
        case rawSelectedMicrophone
        case rawSystemDefault
    }

    enum DeviceApplicationPolicy: Equatable {
        case systemManaged
        case applyConfiguredInput
    }

    enum CaptureFailureAction: Equatable {
        case retryRaw
        case propagate
    }

    enum VoiceProcessingAction: Equatable {
        case keepCurrent
        case setRequested
        case replaceWithRawEngine
    }

    enum RawCapturePostconditionAction: Equatable {
        case accept
        case replaceEngine
        case abort
    }

    enum ConfiguredDeviceVerificationAction: Equatable {
        case accept
        case abortMismatch
        case abortQueryFailure
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
    private var sampleConsumer: (@Sendable ([Float]) -> CaptureJournalWriter.EnqueueResult)?
    private var onConsumerFailure: (@Sendable (CaptureJournalWriter.EnqueueResult) -> Void)?
    private var didReportConsumerFailure = false
    private var signalWatchdog = MicrophoneSignalWatchdog()
    private var onSignalDecision: (@Sendable (MicrophoneSignalWatchdog.Decision) -> Void)?
    private var configurationObserver: NSObjectProtocol?
    private var activeDeviceUID: String?
    private var activeNoiseSuppression = false

    private(set) var captureWarnings: [String] = []

    nonisolated static func captureRoute(
        deviceUID: String?,
        noiseSuppression: Bool
    ) -> CaptureRoute {
        if deviceUID != nil {
            return noiseSuppression
                ? .rawSelectedMicrophoneSuppressionUnavailable
                : .rawSelectedMicrophone
        }
        return noiseSuppression ? .voiceProcessedSystemDefault : .rawSystemDefault
    }

    nonisolated static func captureWarning(for route: CaptureRoute) -> String? {
        guard route == .rawSelectedMicrophoneSuppressionUnavailable else { return nil }
        return "Noise suppression is unavailable with a selected microphone — using raw microphone audio"
    }

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

    nonisolated static func captureWarnings(_ existing: [String], rollingBackTo count: Int) -> [String] {
        Array(existing.prefix(count))
    }

    nonisolated static func deviceApplicationPolicy(
        effectiveVoiceProcessing: Bool
    ) -> DeviceApplicationPolicy {
        effectiveVoiceProcessing ? .systemManaged : .applyConfiguredInput
    }

    nonisolated static func captureFailureAction(
        effectiveVoiceProcessing: Bool
    ) -> CaptureFailureAction {
        effectiveVoiceProcessing ? .retryRaw : .propagate
    }

    nonisolated static func rawCapturePostconditionAction(
        effectiveVoiceProcessing: Bool,
        usingReplacementEngine: Bool
    ) -> RawCapturePostconditionAction {
        guard effectiveVoiceProcessing else { return .accept }
        return usingReplacementEngine ? .abort : .replaceEngine
    }

    nonisolated static func configuredDeviceVerificationAction(
        expectedDeviceID: AudioDeviceID,
        effectiveDeviceID: AudioDeviceID?
    ) -> ConfiguredDeviceVerificationAction {
        guard let effectiveDeviceID else { return .abortQueryFailure }
        return effectiveDeviceID == expectedDeviceID ? .accept : .abortMismatch
    }

    /// Starts capturing. Throws if the mic can't be opened (e.g. permission denied).
    /// - Parameter deviceUID: CoreAudio UID of the input device to pin (AppSettings
    ///   `microphoneDeviceUID`), or nil to use the system default input.
    func start(
        deviceUID: String?,
        noiseSuppression: Bool,
        captureID: UUID? = nil,
        sampleConsumer: (@Sendable ([Float]) -> CaptureJournalWriter.EnqueueResult)? = nil,
        onConsumerFailure: (@Sendable (CaptureJournalWriter.EnqueueResult) -> Void)? = nil,
        onSignalDecision: (@Sendable (MicrophoneSignalWatchdog.Decision) -> Void)? = nil
    ) throws {
        samplesLock.lock()
        samples.removeAll()
        conversionFailureCount = 0
        self.sampleConsumer = sampleConsumer
        self.onConsumerFailure = onConsumerFailure
        self.onSignalDecision = onSignalDecision
        signalWatchdog = MicrophoneSignalWatchdog(captureID: captureID)
        activeDeviceUID = deviceUID
        activeNoiseSuppression = noiseSuppression
        didReportConsumerFailure = false
        samplesLock.unlock()
        converter = nil
        captureWarnings.removeAll()

        let route = Self.captureRoute(deviceUID: deviceUID, noiseSuppression: noiseSuppression)
        if let warning = Self.captureWarning(for: route) {
            recordWarning(warning)
        }
        let requestedVoiceProcessing = route == .voiceProcessedSystemDefault

        let attemptWarningStart = captureWarnings.count
        do {
            try startCaptureAttempt(
                deviceUID: deviceUID,
                requestedVoiceProcessing: requestedVoiceProcessing
            )
        } catch {
            guard Self.captureFailureAction(
                effectiveVoiceProcessing: engine.inputNode.isVoiceProcessingEnabled
            ) == .retryRaw else {
                throw error
            }

            Self.logger.error("Voice-processing capture failed: \(error.localizedDescription, privacy: .public)")
            captureWarnings = Self.captureWarnings(captureWarnings, rollingBackTo: attemptWarningStart)
            try replaceWithRawEngine()
            recordWarning("Voice processing failed — using raw microphone audio")
            try startCaptureAttempt(deviceUID: deviceUID, requestedVoiceProcessing: false)
        }
        samplesLock.withLock { isCapturing = true }
        installConfigurationObserver(captureID: captureID)
    }

    func restartAfterCorroboratedFault() throws {
        samplesLock.lock()
        let capturing = isCapturing
        let deviceUID = activeDeviceUID
        let noiseSuppression = activeNoiseSuppression
        samplesLock.unlock()
        guard capturing else { throw CaptureError.engineStartFailed("capture is no longer active") }

        removeConfigurationObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        let route = Self.captureRoute(deviceUID: deviceUID, noiseSuppression: noiseSuppression)
        do {
            try startCaptureAttempt(
                deviceUID: deviceUID,
                requestedVoiceProcessing: route == .voiceProcessedSystemDefault
            )
            installConfigurationObserver(captureID: signalWatchdog.captureID)
        } catch {
            samplesLock.withLock { isCapturing = false }
            throw error
        }
    }

    nonisolated static func consumerFailureAction(
        for result: CaptureJournalWriter.EnqueueResult
    ) -> ConsumerFailureAction {
        result == .accepted ? .none : .escalate
    }

    private func startCaptureAttempt(deviceUID: String?, requestedVoiceProcessing: Bool) throws {
        var input: AVAudioInputNode?
        var tapInstalled = false
        do {
            let attemptInput = try reconcileVoiceProcessing(requested: requestedVoiceProcessing)
            input = attemptInput
            let effectiveVoiceProcessing = attemptInput.isVoiceProcessingEnabled

            switch Self.deviceApplicationPolicy(effectiveVoiceProcessing: effectiveVoiceProcessing) {
            case .systemManaged:
                verifySystemManagedInput(uid: deviceUID)
            case .applyConfiguredInput:
                try applyConfiguredInputDevice(uid: deviceUID, to: attemptInput)
            }

            let inputFormat = attemptInput.outputFormat(forBus: 0)
            Self.logger.info("Negotiated input format: \(inputFormat.description, privacy: .public)")
            guard let negotiatedConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw CaptureError.converterUnavailable(inputFormat.description)
            }
            converter = negotiatedConverter

            attemptInput.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.consume(buffer: buffer, inputFormat: inputFormat)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
        } catch {
            if tapInstalled {
                input?.removeTap(onBus: 0)
            }
            engine.stop()
            converter = nil
            throw error
        }
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
        let wasCapturing = samplesLock.withLock {
            let value = isCapturing
            isCapturing = false
            return value
        }
        if wasCapturing {
            removeConfigurationObserver()
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

    func signalDiagnostics() -> (peak: Float, rms: Float, hasObservedSignal: Bool) {
        samplesLock.withLock {
            (signalWatchdog.peak, signalWatchdog.rms, signalWatchdog.hasObservedSignal)
        }
    }

    private func installConfigurationObserver(captureID: UUID?) {
        removeConfigurationObserver()
        guard let captureID else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.reportFault(.engine(
                captureID: captureID,
                message: "The audio input configuration changed unexpectedly."
            ))
        }
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    func reportFault(_ fault: AudioCaptureFault) {
        let payload = samplesLock.withLock { () -> ((@Sendable (MicrophoneSignalWatchdog.Decision) -> Void)?, MicrophoneSignalWatchdog.Decision)? in
            guard isCapturing else { return nil }
            let decision = signalWatchdog.observe(peak: 0, rms: 0, fault: fault)
            return (onSignalDecision, decision)
        }
        if let payload { payload.0?(payload.1) }
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

        if !requested,
           Self.rawCapturePostconditionAction(
               effectiveVoiceProcessing: input.isVoiceProcessingEnabled,
               usingReplacementEngine: false
           ) == .replaceEngine {
            Self.logger.error("Voice processing remained enabled after requesting raw capture")
            try replaceWithRawEngine()
            input = engine.inputNode
        }

        Self.logger.info("Voice processing requested=\(requested) effective=\(input.isVoiceProcessingEnabled)")
        return input
    }

    private func replaceWithRawEngine() throws {
        engine.stop()
        converter = nil
        engine = AVAudioEngine()
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled {
            do {
                try input.setVoiceProcessingEnabled(false)
            } catch {
                throw CaptureError.rawFallbackUnavailable(error.localizedDescription)
            }
        }
        guard Self.rawCapturePostconditionAction(
            effectiveVoiceProcessing: input.isVoiceProcessingEnabled,
            usingReplacementEngine: true
        ) == .accept else {
            throw CaptureError.rawFallbackUnavailable("voice processing remained enabled")
        }
        Self.logger.warning("Recreated audio engine for raw-capture fallback")
    }

    /// Pins the engine's input to the CoreAudio device identified by `uid`, if any. Must run
    /// before reading `input.outputFormat`/installing the tap: switching devices can change the
    /// native sample rate/channel count. No-op (system default stays in effect) when `uid` is
    /// nil. When `uid` is set but cannot be selected and verified as effective, aborts capture
    /// rather than silently recording from the system default.
    private func applyConfiguredInputDevice(uid: String?, to input: AVAudioInputNode) throws {
        guard let uid else { return }
        guard let deviceID = AudioInputDevices.resolveID(forUID: uid) else {
            throw CaptureError.configuredDeviceUnavailable("the microphone is not connected")
        }
        guard let audioUnit = input.audioUnit else {
            throw CaptureError.configuredDeviceUnavailable("the audio input is unavailable")
        }
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw CaptureError.configuredDeviceUnavailable(
                "macOS rejected the microphone selection (status \(status))"
            )
        }

        let effectiveDeviceID = currentDeviceID(for: audioUnit)
        switch Self.configuredDeviceVerificationAction(
            expectedDeviceID: deviceID,
            effectiveDeviceID: effectiveDeviceID
        ) {
        case .accept:
            Self.logger.info("Verified effective input device ID: \(deviceID)")
        case .abortMismatch:
            Self.logger.error(
                "Configured input device ID \(deviceID) did not become effective; got \(effectiveDeviceID ?? 0)"
            )
            throw CaptureError.configuredDeviceUnavailable("macOS selected a different microphone")
        case .abortQueryFailure:
            Self.logger.error("Configured input device ID \(deviceID) could not be verified")
            throw CaptureError.configuredDeviceUnavailable(
                "the selected microphone could not be verified"
            )
        }
    }

    private func recordWarning(_ warning: String) {
        captureWarnings = Self.captureWarnings(captureWarnings, adding: warning)
    }

    private func verifySystemManagedInput(uid: String?) {
        let effectiveDeviceID = systemDefaultInputDeviceID()
        if let effectiveDeviceID {
            Self.logger.info("Effective voice-processing input device ID: \(effectiveDeviceID)")
        } else {
            Self.logger.error("Effective voice-processing input device unknown: system default input query failed")
        }
        guard let uid else { return }
        guard let configuredDeviceID = AudioInputDevices.resolveID(forUID: uid) else {
            recordWarning("Configured microphone not found — voice processing is using the system microphone")
            return
        }
        guard let effectiveDeviceID else {
            recordWarning("Voice processing could not confirm the configured microphone — using system-managed audio")
            return
        }
        guard effectiveDeviceID == configuredDeviceID else {
            recordWarning("Voice processing is using the system microphone instead of the configured microphone")
            return
        }
    }

    private func systemDefaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr else { return nil }
        return deviceID
    }

    private func currentDeviceID(for audioUnit: AudioUnit) -> AudioDeviceID? {
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
            Self.logger.error("Effective input device unknown: CurrentDevice property query failed with status \(status)")
            return nil
        }
        return deviceID
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
        let convertedSamples = Array(
            UnsafeBufferPointer(start: channelData[0], count: frameCount)
        )
        samplesLock.lock()
        samples.append(contentsOf: convertedSamples)
        let consumer = sampleConsumer
        let failureHandler = onConsumerFailure
        let signalDecision = signalWatchdog.observe(samples: convertedSamples)
        let signalHandler = onSignalDecision
        samplesLock.unlock()
        if signalDecision != .continueRecording {
            signalHandler?(signalDecision)
        }
        guard let consumer else { return }
        let result = consumer(convertedSamples)
        guard Self.consumerFailureAction(for: result) == .escalate else { return }
        let shouldReport = samplesLock.withLock {
            guard !didReportConsumerFailure else { return false }
            didReportConsumerFailure = true
            return true
        }
        if shouldReport, let failureHandler {
            Task { failureHandler(result) }
        }
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
    case configuredDeviceUnavailable(String)
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case let .converterUnavailable(format):
            "Could not convert microphone format \(format) to 16 kHz mono audio"
        case let .rawFallbackUnavailable(reason):
            "Could not establish raw microphone capture after voice-processing failure: \(reason)"
        case let .configuredDeviceUnavailable(reason):
            "Could not use the configured microphone because \(reason). Recording was not started."
        case let .engineStartFailed(reason):
            "Could not restart microphone capture: \(reason)"
        }
    }
}
