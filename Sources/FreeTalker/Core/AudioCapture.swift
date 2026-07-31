import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
import ObjCExceptionBridge
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
        /// The capture graph is not running and the restart budget is spent — stop the recording
        /// with a visible error instead of leaving a live-looking HUD over a dead engine.
        case abortForRouteFailure(String)
    }

    static let signalFloor: Float = 1e-7

    let captureID: UUID?
    private(set) var hasObservedSignal = false
    private(set) var didRequestRestart = false
    private(set) var observationCount = 0
    private(set) var peak: Float = 0
    private(set) var rms: Float = 0
    private(set) var routeFailure: String?
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

    /// Records the failure text surfaced at stop time. The restart/abort verdict itself is
    /// `AudioCapture.routeFaultAction`'s, not this type's — see `AudioCapture.deliver`.
    mutating func recordRouteFailure(_ message: String) {
        if routeFailure == nil { routeFailure = message }
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
           captureID == nil || fault.captureID == captureID {
            if routeFailure == nil { routeFailure = fault.message }
            guard !didRequestRestart else { return .continueRecording }
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

final class AudioCaptureGenerationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var activeGeneration: UUID?
    private var accepting = false
    private var inFlight = 0

    func activate() -> UUID {
        condition.withLock {
            precondition(activeGeneration == nil && inFlight == 0)
            let generation = UUID()
            activeGeneration = generation
            accepting = true
            return generation
        }
    }

    func begin(_ generation: UUID) -> Bool {
        condition.withLock {
            guard accepting, activeGeneration == generation else { return false }
            inFlight += 1
            return true
        }
    }

    func finish(_ generation: UUID) {
        condition.lock()
        if activeGeneration == generation, inFlight > 0 {
            inFlight -= 1
            if inFlight == 0 { condition.broadcast() }
        }
        condition.unlock()
    }

    func deactivateAndWait() {
        condition.lock()
        accepting = false
        while inFlight > 0 { condition.wait() }
        activeGeneration = nil
        condition.unlock()
    }

    func isCurrent(_ generation: UUID) -> Bool {
        condition.withLock { activeGeneration == generation }
    }

    var currentGeneration: UUID? {
        condition.withLock { activeGeneration }
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

    enum ConverterCacheAction: Equatable {
        case reuse
        case rebuild
    }

    enum RouteFaultAction: Equatable {
        case restart
        case abort
        case ignore
    }

    enum ConvertedBufferAction: Equatable {
        case accept
        case unusable
    }

    enum UnusableAudioAction: Equatable {
        case escalate
        case ignore
    }

    enum FaultKind: Equatable {
        /// The graph reported it is no longer running (configuration change, conversion collapse).
        case routeChange
        /// The tap was installed but has delivered nothing — see `armFirstBufferDeadline`.
        case starvedTap
    }

    /// What a fault report should do, and the state it leaves behind. Returned as a whole so the
    /// verdict, the restart budget and the duplicate latch are decided in one place — computing
    /// them separately is how two faults for one attempt each managed to spend a restart.
    struct FaultResolution: Equatable {
        var decision: MicrophoneSignalWatchdog.Decision?
        var restartsUsed: Int
        var faultedGeneration: UUID?
    }

    enum ConfiguredDeviceVerificationAction: Equatable {
        case accept
        case abortMismatch
        case abortQueryFailure
    }

    private static let logger = Logger(subsystem: "org.freetalker.app", category: "audio-capture")
    private var engine = AVAudioEngine()
    private let generationGate = AudioCaptureGenerationGate()
    private var samples: [Float] = []
    // Guards `samples` and `conversionFailureCount`, which cross the tap and main threads.
    private let samplesLock = NSLock()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var isCapturing = false
    private var conversionFailureCount = 0
    /// Converter from the tap's *live* input format to `targetFormat`, built lazily from the first
    /// buffer and rebuilt whenever the bus renegotiates mid-capture. Pinning a converter to a
    /// format read before the graph settled is what broke capture — see `startCaptureAttempt`.
    /// Both guarded by `samplesLock`.
    private var tapConverter: AVAudioConverter?
    private var tapConverterFormat: AVAudioFormat?
    /// Tap callbacks delivered by the CURRENT attempt, counted before any conversion work so a
    /// conversion failure is never mistaken for a tap that never fired. Reset per attempt;
    /// `MicrophoneSignalWatchdog.observationCount` cannot serve here because it is capture-wide
    /// and is also incremented by out-of-band fault reports. Guarded by `samplesLock`.
    private var tapCallbackCount = 0
    /// Per-attempt conversion outcome, for the unusable-audio escalation below: input seconds that
    /// failed to convert, whether anything converted at all, and whether the escalation already
    /// fired. Per attempt, not per capture — a capture-wide counter cannot escalate a second time
    /// after a restart, which leaves the replacement attempt free to be silent forever. Guarded by
    /// `samplesLock`.
    private var attemptUnusableSeconds: TimeInterval = 0
    private var attemptConvertedAnything = false
    private var attemptUnusableEscalated = false
    /// Route faults already answered with a restart, for the whole capture. Guarded by `samplesLock`.
    private var routeRestartCount = 0
    /// The attempt a route-fault decision has already been emitted for. A configuration
    /// notification and the first-buffer deadline can both fire for the same dead attempt;
    /// without this each would charge the restart budget and enqueue its own decision, and the
    /// second could land on the attempt that had already replaced the faulted one. Guarded by
    /// `samplesLock`.
    private var faultedGeneration: UUID?
    /// Voice-processing state of the attempt in progress — see the `catch` in `start`.
    private var attemptVoiceProcessing = false
    private var sampleConsumer: (@Sendable ([Float]) -> CaptureJournalWriter.EnqueueResult)?
    /// Optional live-tap fan-out (Streaming ASR): receives each converted buffer's samples
    /// alongside `sampleConsumer`, purely additively — `samples` accumulation and
    /// `sampleConsumer`'s durable-journal write are completely untouched by this. A throwing/slow
    /// consumer here must never affect capture, so it's fire-and-forget from `consume`.
    private var liveSampleConsumer: (@Sendable ([Float]) -> Void)?
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

    /// How long after `engine.start()` an attempt that has received no tap callback at all is
    /// treated as starved rather than merely quiet. A heuristic tuned for a USB microphone's cold
    /// start, not a documented guarantee — `armFirstBufferDeadline` logs when it fires so the
    /// value can be revisited against real hardware.
    static let firstBufferDeadline: TimeInterval = 2

    /// Route faults answered with a restart before the capture is given up on.
    static let maximumRouteRestarts = 2

    /// How much arriving-but-unusable audio an attempt may accumulate, having converted nothing,
    /// before it is treated as dead. Measured in input seconds rather than buffers so it means
    /// the same thing at 16 kHz and at 48 kHz.
    static let unusableAudioDeadline: TimeInterval = 2

    static let noAudioDeliveredMessage = "The microphone delivered no audio."

    static let unusableAudioMessage = "The microphone audio could not be processed."

    /// A tap that never fires is invisible to `MicrophoneSignalWatchdog`, which only ever observes
    /// buffers that actually arrive: AVAudioEngine can accept `installTap` and still deliver
    /// nothing ("Failed to create tap, config change pending!"), and `engine.start()` succeeds
    /// either way — which is how a whole dictation was recorded as zero frames with no error
    /// anywhere. Zero callbacks is a different failure from zero amplitude, so it is counted per
    /// attempt and answered here.
    nonisolated static func starvedCaptureAction(
        isCapturing: Bool,
        tapCallbackCount: Int,
        restartsUsed: Int
    ) -> RouteFaultAction {
        guard isCapturing, tapCallbackCount == 0 else { return .ignore }
        return routeFaultAction(isCapturing: isCapturing, restartsUsed: restartsUsed)
    }

    /// Whether a converted buffer carries usable audio. Zero frames from a non-error conversion
    /// counts as unusable input — see `consume`.
    nonisolated static func convertedBufferAction(frameCount: Int) -> ConvertedBufferAction {
        frameCount > 0 ? .accept : .unusable
    }

    /// Whether an attempt that has converted nothing has now accumulated enough unusable input to
    /// be given up on. Fires at most once per attempt; `alreadyEscalated` is what makes it once.
    nonisolated static func unusableAudioAction(
        convertedAnything: Bool,
        alreadyEscalated: Bool,
        unusableSeconds: TimeInterval
    ) -> UnusableAudioAction {
        guard !convertedAnything, !alreadyEscalated,
              unusableSeconds >= unusableAudioDeadline
        else { return .ignore }
        return .escalate
    }

    /// One fault report resolved against the capture's current state. At most one decision is
    /// produced per attempt (`generation`): a configuration notification and the first-buffer
    /// deadline can both fire for the same dead attempt, and charging the restart budget twice
    /// for one failure would burn it before the capture has really been retried.
    nonisolated static func resolveFault(
        kind: FaultKind,
        message: String,
        generation: UUID,
        faultedGeneration: UUID?,
        isCapturing: Bool,
        tapCallbackCount: Int,
        restartsUsed: Int
    ) -> FaultResolution {
        let unchanged = FaultResolution(
            decision: nil, restartsUsed: restartsUsed, faultedGeneration: faultedGeneration
        )
        guard faultedGeneration != generation else { return unchanged }
        let action: RouteFaultAction
        switch kind {
        case .routeChange:
            action = routeFaultAction(isCapturing: isCapturing, restartsUsed: restartsUsed)
        case .starvedTap:
            action = starvedCaptureAction(
                isCapturing: isCapturing,
                tapCallbackCount: tapCallbackCount,
                restartsUsed: restartsUsed
            )
        }
        switch action {
        case .ignore:
            return unchanged
        case .restart:
            return FaultResolution(
                decision: .restartForRouteFailure(message),
                restartsUsed: restartsUsed + 1,
                faultedGeneration: generation
            )
        case .abort:
            return FaultResolution(
                decision: .abortForRouteFailure(message),
                restartsUsed: restartsUsed,
                faultedGeneration: generation
            )
        }
    }

    /// What to do about a fault that means the capture graph is no longer running: restart while
    /// restarts remain, then give up visibly.
    ///
    /// Deliberately independent of whether signal was already observed. An
    /// `AVAudioEngineConfigurationChange` is posted after the engine has been stopped and
    /// uninitialized, so "we heard audio a moment ago" says nothing about whether audio is still
    /// being captured — treating that as a reason to ignore the fault leaves a recording that
    /// looks live and records nothing.
    nonisolated static func routeFaultAction(
        isCapturing: Bool,
        restartsUsed: Int
    ) -> RouteFaultAction {
        guard isCapturing else { return .ignore }
        return restartsUsed < maximumRouteRestarts ? .restart : .abort
    }

    /// Whether the cached tap converter still matches what the tap is delivering. The tap follows
    /// the input bus's live format (`installTap(format: nil)`), and that format can change
    /// mid-capture — a device switch or a voice-processing transition renegotiates the bus — so a
    /// converter pinned to an earlier format would silently resample against the wrong input rate.
    nonisolated static func converterCacheAction(
        cachedFormat: AVAudioFormat?,
        incomingFormat: AVAudioFormat
    ) -> ConverterCacheAction {
        guard let cachedFormat else { return .rebuild }
        return cachedFormat == incomingFormat ? .reuse : .rebuild
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
        onSignalDecision: (@Sendable (MicrophoneSignalWatchdog.Decision) -> Void)? = nil,
        liveSampleConsumer: (@Sendable ([Float]) -> Void)? = nil
    ) throws {
        samplesLock.lock()
        samples.removeAll()
        conversionFailureCount = 0
        self.sampleConsumer = sampleConsumer
        self.onConsumerFailure = onConsumerFailure
        self.onSignalDecision = onSignalDecision
        self.liveSampleConsumer = liveSampleConsumer
        signalWatchdog = MicrophoneSignalWatchdog(captureID: captureID)
        tapCallbackCount = 0
        routeRestartCount = 0
        activeDeviceUID = deviceUID
        activeNoiseSuppression = noiseSuppression
        didReportConsumerFailure = false
        samplesLock.unlock()
        captureWarnings.removeAll()

        let route = Self.captureRoute(deviceUID: deviceUID, noiseSuppression: noiseSuppression)
        if let warning = Self.captureWarning(for: route) {
            recordWarning(warning)
        }
        let requestedVoiceProcessing = route == .voiceProcessedSystemDefault

        let attemptWarningStart = captureWarnings.count
        do {
            let generation = try startCaptureAttempt(
                deviceUID: deviceUID,
                requestedVoiceProcessing: requestedVoiceProcessing
            )
            installConfigurationObserver(captureID: captureID, generation: generation)
        } catch {
            // The failed attempt's voice-processing state, not the current engine's: a graph that
            // raised has already been discarded by `startCaptureAttempt`, and a fresh
            // `AVAudioEngine` reports voice processing off, which would suppress the raw retry.
            guard Self.captureFailureAction(
                effectiveVoiceProcessing: attemptVoiceProcessing
            ) == .retryRaw else {
                throw error
            }

            Self.logger.error("Voice-processing capture failed: \(error.localizedDescription, privacy: .public)")
            captureWarnings = Self.captureWarnings(captureWarnings, rollingBackTo: attemptWarningStart)
            try replaceWithRawEngine()
            recordWarning("Voice processing failed — using raw microphone audio")
            let generation = try startCaptureAttempt(
                deviceUID: deviceUID, requestedVoiceProcessing: false
            )
            installConfigurationObserver(captureID: captureID, generation: generation)
        }
    }

    func restartAfterCorroboratedFault() throws {
        let state = samplesLock.withLock {
            (
                capturing: isCapturing,
                deviceUID: activeDeviceUID,
                noiseSuppression: activeNoiseSuppression,
                captureID: signalWatchdog.captureID
            )
        }
        guard state.capturing else { throw CaptureError.engineStartFailed("capture is no longer active") }

        removeConfigurationObserver()
        generationGate.deactivateAndWait()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let route = Self.captureRoute(
            deviceUID: state.deviceUID, noiseSuppression: state.noiseSuppression
        )
        do {
            let generation = try startCaptureAttempt(
                deviceUID: state.deviceUID,
                requestedVoiceProcessing: route == .voiceProcessedSystemDefault
            )
            installConfigurationObserver(
                captureID: state.captureID, generation: generation
            )
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

    private func startCaptureAttempt(
        deviceUID: String?, requestedVoiceProcessing: Bool
    ) throws -> UUID {
        var input: AVAudioInputNode?
        var tapInstalled = false
        let generation = generationGate.activate()
        samplesLock.withLock { isCapturing = true }
        do {
            let attemptInput = try reconcileVoiceProcessing(requested: requestedVoiceProcessing)
            input = attemptInput
            let effectiveVoiceProcessing = attemptInput.isVoiceProcessingEnabled
            // Remembered because the engine this attempt used may be discarded below: `start`'s
            // fallback decision is about the attempt that failed, not about its replacement.
            attemptVoiceProcessing = effectiveVoiceProcessing

            switch Self.deviceApplicationPolicy(effectiveVoiceProcessing: effectiveVoiceProcessing) {
            case .systemManaged:
                verifySystemManagedInput(uid: deviceUID)
            case .applyConfiguredInput:
                try applyConfiguredInputDevice(uid: deviceUID, to: attemptInput)
            }

            // `format: nil` — the tap follows the input bus's live format instead of one read
            // here. A non-nil format is a request to APPLY that format to the tapped bus, and
            // applying the configured device above (or the voice-processing transition before it)
            // renegotiates the bus asynchronously, so a format read here can be forced onto a
            // graph that has already moved. Observed on a 16 kHz USB mic: 48 kHz forced, 16 kHz
            // hardware input scope, and AVAudioEngine then either installs nothing at all
            // ("Failed to create tap, config change pending!" — capture runs to completion with
            // zero frames, which is what left recovery jobs stuck at `preparing` with progress 0)
            // or raises an NSException ("Failed to create tap due to format mismatch"), after
            // which the process crashed at an unrelated MainActor isolation check. See
            // docs/dictation-zero-audio-crash-2026-07-31.md.
            samplesLock.withLock {
                tapConverter = nil
                tapConverterFormat = nil
                tapCallbackCount = 0
                attemptUnusableSeconds = 0
                attemptConvertedAnything = false
                attemptUnusableEscalated = false
            }
            // Contained in Objective-C: Swift cannot catch the NSException this raises, and an
            // uncaught one unwinding out of here is what preceded the crash.
            var tapException: NSError?
            let installed = FTInstallTapCatchingException(
                attemptInput, 0, 4096, nil,
                { [weak self] buffer, _ in self?.consume(buffer: buffer, generation: generation) },
                &tapException
            )
            guard installed else {
                throw CaptureError.graphExceptionRaised(
                    tapException?.localizedDescription ?? "the audio graph rejected the microphone tap"
                )
            }
            Self.logger.info(
                "Installed tap; bus format: \(attemptInput.outputFormat(forBus: 0).description, privacy: .public)"
            )
            tapInstalled = true
            engine.prepare()
            try engine.start()
            armFirstBufferDeadline(generation: generation)
            return generation
        } catch {
            // A graph that raised is in an unknown state: it gets discarded WITHOUT another call
            // on it — not even `stop()`/`removeTap` — and the next attempt starts from a fresh
            // engine. Every other failure unwinds normally and is cleaned up in place.
            if let captureError = error as? CaptureError, case .graphExceptionRaised = captureError {
                engine = AVAudioEngine()
                Self.logger.error(
                    "Audio graph raised an exception; discarded the engine: \(error.localizedDescription, privacy: .public)"
                )
            } else {
                if tapInstalled {
                    input?.removeTap(onBus: 0)
                }
                engine.stop()
            }
            generationGate.deactivateAndWait()
            samplesLock.withLock { isCapturing = false }
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
            generationGate.deactivateAndWait()
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

    func signalDiagnostics() -> (
        peak: Float, rms: Float, hasObservedSignal: Bool, routeFailure: String?
    ) {
        samplesLock.withLock {
            (
                signalWatchdog.peak, signalWatchdog.rms,
                signalWatchdog.hasObservedSignal, signalWatchdog.routeFailure
            )
        }
    }

    /// Escalates an attempt whose tap never fired — see `starvedCaptureAction`. Reported through
    /// the same path as a configuration change, so it shares the capture-wide restart budget and
    /// ends in `.abortForRouteFailure` once that budget is spent.
    private func armFirstBufferDeadline(generation: UUID) {
        guard let captureID = samplesLock.withLock({ signalWatchdog.captureID }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstBufferDeadline) { [weak self] in
            guard let self else { return }
            let escalated = self.emitFault(
                .engine(captureID: captureID, message: Self.noAudioDeliveredMessage),
                kind: .starvedTap,
                generation: generation
            )
            if escalated {
                Self.logger.error(
                    "No audio buffers arrived within \(Self.firstBufferDeadline, privacy: .public)s of engine start"
                )
            }
        }
    }

    private func installConfigurationObserver(captureID: UUID?, generation: UUID) {
        removeConfigurationObserver()
        guard let captureID else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.reportFault(
                .engine(
                    captureID: captureID,
                    message: "The audio input configuration changed unexpectedly."
                ),
                generation: generation
            )
        }
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    func reportFault(_ fault: AudioCaptureFault) {
        guard let generation = generationGate.currentGeneration else { return }
        reportFault(fault, generation: generation)
    }

    private func reportFault(_ fault: AudioCaptureFault, generation: UUID) {
        emitFault(fault, kind: .routeChange, generation: generation)
    }

    /// Turns a fault into the decision the coordinator acts on, recording the failure text on the
    /// watchdog for the stop-time diagnostics either way. The verdict comes from
    /// `routeFaultAction`/`starvedCaptureAction`, not from `MicrophoneSignalWatchdog.observe`,
    /// because the watchdog answers "is this capture silent?" while this answers "is this capture
    /// still running?" — and a capture that has already heard signal can still have had its
    /// engine stopped.
    ///
    /// Verdict, budget and latch are decided under one lock: computing the action separately from
    /// charging the budget lets two faults for the same attempt each spend a restart.
    ///
    /// Returns whether a decision was emitted.
    @discardableResult
    private func emitFault(
        _ fault: AudioCaptureFault, kind: FaultKind, generation: UUID
    ) -> Bool {
        guard generationGate.isCurrent(generation) else { return false }
        let payload = samplesLock.withLock {
            () -> ((@Sendable (MicrophoneSignalWatchdog.Decision) -> Void)?, MicrophoneSignalWatchdog.Decision)? in
            guard isCapturing, generationGate.isCurrent(generation),
                  signalWatchdog.captureID == nil || fault.captureID == signalWatchdog.captureID
            else { return nil }
            let resolution = Self.resolveFault(
                kind: kind,
                message: fault.message,
                generation: generation,
                faultedGeneration: faultedGeneration,
                isCapturing: isCapturing,
                tapCallbackCount: tapCallbackCount,
                restartsUsed: routeRestartCount
            )
            routeRestartCount = resolution.restartsUsed
            faultedGeneration = resolution.faultedGeneration
            guard let decision = resolution.decision else { return nil }
            signalWatchdog.recordRouteFailure(fault.message)
            return (onSignalDecision, decision)
        }
        guard let payload else { return false }
        payload.0?(payload.1)
        return true
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

    /// Converter for the format the tap is actually delivering, cached across buffers and rebuilt
    /// when the bus renegotiates. Returns nil only when CoreAudio cannot convert that format at
    /// all, which `consume` treats as a conversion failure.
    private func converter(for inputFormat: AVAudioFormat) -> AVAudioConverter? {
        samplesLock.withLock {
            if let tapConverter, Self.converterCacheAction(
                cachedFormat: tapConverterFormat, incomingFormat: inputFormat
            ) == .reuse {
                return tapConverter
            }
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                return nil
            }
            tapConverter = converter
            tapConverterFormat = inputFormat
            return converter
        }
    }

    private func consume(buffer: AVAudioPCMBuffer, generation: UUID) {
        guard generationGate.begin(generation) else { return }
        defer { generationGate.finish(generation) }
        // Counted here, before any conversion work: the tap fired, which is what the first-buffer
        // deadline asks about. A conversion failure is a different fault and must not read as
        // "the tap never fired".
        samplesLock.withLock { tapCallbackCount += 1 }
        // The buffer's own format is authoritative — see `installTap(format: nil)` above.
        let inputFormat = buffer.format
        let inputSeconds = inputFormat.sampleRate > 0
            ? Double(buffer.frameLength) / inputFormat.sampleRate
            : 0
        guard let converter = converter(for: inputFormat) else {
            Self.logger.error(
                "No converter available for tap format \(inputFormat.description, privacy: .public)"
            )
            recordConversionFailure(generation: generation, inputSeconds: inputSeconds)
            return
        }
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            recordConversionFailure(generation: generation, inputSeconds: inputSeconds)
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
            recordConversionFailure(generation: generation, inputSeconds: inputSeconds)
            return
        }
        guard let channelData = outBuffer.floatChannelData else {
            recordConversionFailure(generation: generation, inputSeconds: inputSeconds)
            return
        }
        let frameCount = Int(outBuffer.frameLength)
        // A conversion that did not error can still produce nothing — `.inputRanDry` returns as
        // much as could be converted, which may be zero frames. That is unusable input, not a
        // healthy attempt: counting it as healthy would satisfy both deadlines while the journal
        // stays empty, which is the failure they exist to catch.
        guard Self.convertedBufferAction(frameCount: frameCount) == .accept else {
            recordConversionFailure(generation: generation, inputSeconds: inputSeconds)
            return
        }
        let convertedSamples = Array(
            UnsafeBufferPointer(start: channelData[0], count: frameCount)
        )
        guard generationGate.isCurrent(generation) else { return }
        samplesLock.lock()
        samples.append(contentsOf: convertedSamples)
        attemptConvertedAnything = true
        let consumer = sampleConsumer
        let liveConsumer = liveSampleConsumer
        let failureHandler = onConsumerFailure
        let signalDecision = signalWatchdog.observe(samples: convertedSamples)
        let signalHandler = onSignalDecision
        samplesLock.unlock()
        if signalDecision != .continueRecording {
            signalHandler?(signalDecision)
        }
        // Durable journal write happens BEFORE the optional live fan-out (Codex finding 8) — the
        // fan-out must never be able to delay or gate the write that Recovery depends on.
        if let consumer {
            let result = consumer(convertedSamples)
            if Self.consumerFailureAction(for: result) == .escalate {
                let shouldReport = samplesLock.withLock {
                    guard !didReportConsumerFailure else { return false }
                    didReportConsumerFailure = true
                    return true
                }
                if shouldReport, let failureHandler {
                    Task { failureHandler(result) }
                }
            }
        }
        // Fire-and-forget, purely additive fan-out — never gates or affects `samples`/the durable
        // `sampleConsumer` write above, which stay exactly as they are without Streaming ASR.
        liveConsumer?(convertedSamples)
    }

    private func recordConversionFailure(generation: UUID, inputSeconds: TimeInterval) {
        guard generationGate.isCurrent(generation) else { return }
        // Callbacks that arrive but never convert are as dead as callbacks that never arrive: the
        // first-buffer deadline is satisfied, the journal stays empty, and the HUD keeps saying
        // the recording is live. Escalated once per attempt, and only while the attempt has
        // converted nothing at all.
        let escalation = samplesLock.withLock { () -> UUID? in
            conversionFailureCount += 1
            attemptUnusableSeconds += inputSeconds
            guard Self.unusableAudioAction(
                convertedAnything: attemptConvertedAnything,
                alreadyEscalated: attemptUnusableEscalated,
                unusableSeconds: attemptUnusableSeconds
            ) == .escalate else { return nil }
            attemptUnusableEscalated = true
            return signalWatchdog.captureID
        }
        guard let captureID = escalation else { return }
        Self.logger.error(
            "\(Self.unusableAudioDeadline, privacy: .public)s of tap audio failed to convert with nothing captured"
        )
        emitFault(
            .engine(captureID: captureID, message: Self.unusableAudioMessage),
            kind: .routeChange,
            generation: generation
        )
    }
}

private enum CaptureError: LocalizedError {
    case graphExceptionRaised(String)
    case rawFallbackUnavailable(String)
    case configuredDeviceUnavailable(String)
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case let .graphExceptionRaised(reason):
            "The audio system rejected the microphone tap: \(reason)"
        case let .rawFallbackUnavailable(reason):
            "Could not establish raw microphone capture after voice-processing failure: \(reason)"
        case let .configuredDeviceUnavailable(reason):
            "Could not use the configured microphone because \(reason). Recording was not started."
        case let .engineStartFailed(reason):
            "Could not restart microphone capture: \(reason)"
        }
    }
}
