import AVFoundation
import Testing
@testable import FreeTalker

struct AudioCaptureDecisionTests {
    private static func format(sampleRate: Double, channels: AVAudioChannelCount = 1) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
    }

    /// A tap that is accepted but never fires delivers no observations at all, so the watchdog's
    /// silent-buffer warning can never trigger — the zero-frame dictation in
    /// docs/dictation-zero-audio-crash-2026-07-31.md went unreported for exactly that reason.
    @Test func captureWithoutASingleTapCallbackIsRestarted() {
        #expect(
            AudioCapture.starvedCaptureAction(
                isCapturing: true, convertedAnything: false, restartsUsed: 0
            ) == .restart
        )
    }

    @Test func captureDeliveringBuffersIsLeftAlone() {
        #expect(
            AudioCapture.starvedCaptureAction(
                isCapturing: true, convertedAnything: true, restartsUsed: 0
            ) == .ignore
        )
    }

    /// The deadline fires after the recording already stopped — nothing to escalate.
    @Test func finishedCaptureIsLeftAlone() {
        #expect(
            AudioCapture.starvedCaptureAction(
                isCapturing: false, convertedAnything: false, restartsUsed: 0
            ) == .ignore
        )
    }

    /// The restart budget has to run out somewhere: a capture starved again after its restarts
    /// were spent is given up on visibly rather than left running over a dead engine.
    @Test func repeatedlyStarvedCaptureIsAborted() {
        #expect(
            AudioCapture.starvedCaptureAction(
                isCapturing: true,
                convertedAnything: false,
                restartsUsed: AudioCapture.maximumRouteRestarts
            ) == .abort
        )
    }

    /// A configuration change is posted after the engine has already been stopped, so having
    /// heard audio a moment ago is no reason to ignore it.
    @Test func routeFaultRestartsRegardlessOfEarlierSignal() {
        #expect(AudioCapture.routeFaultAction(isCapturing: true, restartsUsed: 0) == .restart)
        #expect(
            AudioCapture.routeFaultAction(
                isCapturing: true, restartsUsed: AudioCapture.maximumRouteRestarts - 1
            ) == .restart
        )
    }

    @Test func routeFaultAbortsOnceTheRestartBudgetIsSpent() {
        #expect(
            AudioCapture.routeFaultAction(
                isCapturing: true, restartsUsed: AudioCapture.maximumRouteRestarts
            ) == .abort
        )
    }

    @Test func routeFaultAfterCaptureEndedIsIgnored() {
        #expect(AudioCapture.routeFaultAction(isCapturing: false, restartsUsed: 0) == .ignore)
    }

    /// Two faults landing on the same attempt — a configuration notification and the first-buffer
    /// deadline both fire for one dead attempt — must cost one restart, not two, and must produce
    /// one decision.
    @Test func aSecondFaultForTheSameAttemptChangesNothing() {
        let generation = UUID()
        let first = AudioCapture.resolveFault(
            kind: .routeChange, message: "route died", generation: generation,
            faultedGeneration: nil, isCapturing: true, convertedAnything: false, restartsUsed: 0
        )
        #expect(first.decision == .restartForRouteFailure("route died"))
        #expect(first.restartsUsed == 1)
        #expect(first.faultedGeneration == generation)

        let second = AudioCapture.resolveFault(
            kind: .starvedTap, message: AudioCapture.noAudioDeliveredMessage,
            generation: generation,
            faultedGeneration: first.faultedGeneration, isCapturing: true,
            convertedAnything: false, restartsUsed: first.restartsUsed
        )
        #expect(second.decision == nil)
        #expect(second.restartsUsed == first.restartsUsed)
        #expect(second.faultedGeneration == generation)
    }

    /// The replacement attempt gets its own decision, and the budget runs out into an abort rather
    /// than leaving a dead capture live. Every attempt here is a fresh generation, as
    /// `generationGate.activate()` guarantees.
    @Test func eachAttemptGetsOneDecisionUntilTheBudgetAborts() {
        var faulted: UUID?
        var restartsUsed = 0
        var decisions: [MicrophoneSignalWatchdog.Decision] = []
        for _ in 0..<(AudioCapture.maximumRouteRestarts + 2) {
            let resolution = AudioCapture.resolveFault(
                kind: .starvedTap, message: "dead", generation: UUID(),
                faultedGeneration: faulted, isCapturing: true,
                convertedAnything: false, restartsUsed: restartsUsed
            )
            faulted = resolution.faultedGeneration
            restartsUsed = resolution.restartsUsed
            if let decision = resolution.decision { decisions.append(decision) }
        }
        #expect(
            decisions == Array(
                repeating: MicrophoneSignalWatchdog.Decision.restartForRouteFailure("dead"),
                count: AudioCapture.maximumRouteRestarts
            ) + Array(
                repeating: MicrophoneSignalWatchdog.Decision.abortForRouteFailure("dead"),
                count: 2
            )
        )
        #expect(restartsUsed == AudioCapture.maximumRouteRestarts)
    }

    /// A conversion that returns no frames without erroring (`.inputRanDry`) is unusable input, not
    /// a healthy attempt. Counting it as usable would satisfy the deadline's predicate, leaving a
    /// capture that journals nothing under a live HUD.
    @Test func aZeroFrameConversionIsUnusable() {
        #expect(AudioCapture.convertedBufferAction(frameCount: 0) == .unusable)
        #expect(AudioCapture.convertedBufferAction(frameCount: 1) == .accept)
    }

    /// The hole this predicate closes: one callback arrives, converts to nothing, and no further
    /// callback ever comes. A "did any callback arrive?" deadline passes that capture as live
    /// forever; the deadline asks whether anything usable was produced, so it does not.
    @Test func oneUnusableCallbackThenSilenceIsStarved() {
        #expect(
            AudioCapture.starvedCaptureAction(
                isCapturing: true, convertedAnything: false, restartsUsed: 0
            ) == .restart
        )
        #expect(
            AudioCapture.starvedCaptureMessage(tapCallbackCount: 1)
                == AudioCapture.unusableAudioMessage
        )
        #expect(
            AudioCapture.starvedCaptureMessage(tapCallbackCount: 0)
                == AudioCapture.noAudioDeliveredMessage
        )
    }

    /// An attempt that converted real audio is never starved — that is a degraded capture at worst,
    /// and it has audio worth keeping.
    @Test func anAttemptThatProducedUsableAudioIsNeverStarved() {
        #expect(
            AudioCapture.starvedCaptureAction(
                isCapturing: true, convertedAnything: true, restartsUsed: 0
            ) == .ignore
        )
        #expect(
            AudioCapture.starvedCaptureAction(
                isCapturing: true,
                convertedAnything: true,
                restartsUsed: AudioCapture.maximumRouteRestarts
            ) == .ignore
        )
    }

    /// An attempt that is delivering buffers is not starved, whatever the budget says.
    @Test func aLiveAttemptIsNeverFaulted() {
        let resolution = AudioCapture.resolveFault(
            kind: .starvedTap, message: "dead", generation: UUID(),
            faultedGeneration: nil, isCapturing: true, convertedAnything: true, restartsUsed: 0
        )
        #expect(resolution.decision == nil)
        #expect(resolution.faultedGeneration == nil)
        #expect(resolution.restartsUsed == 0)
    }

    @Test func firstTapBufferBuildsAConverter() {
        #expect(
            AudioCapture.converterCacheAction(
                cachedFormat: nil, incomingFormat: Self.format(sampleRate: 48_000)
            ) == .rebuild
        )
    }

    @Test func unchangedTapFormatReusesTheConverter() {
        #expect(
            AudioCapture.converterCacheAction(
                cachedFormat: Self.format(sampleRate: 48_000),
                incomingFormat: Self.format(sampleRate: 48_000)
            ) == .reuse
        )
    }

    /// The regression the zero-audio/crash bug came from: the bus renegotiated from 48 kHz to the
    /// 16 kHz USB microphone after capture started. A converter pinned to the old format would
    /// resample against the wrong input rate — see
    /// docs/dictation-zero-audio-crash-2026-07-31.md.
    @Test func renegotiatedTapFormatRebuildsTheConverter() {
        #expect(
            AudioCapture.converterCacheAction(
                cachedFormat: Self.format(sampleRate: 48_000),
                incomingFormat: Self.format(sampleRate: 16_000)
            ) == .rebuild
        )
        #expect(
            AudioCapture.converterCacheAction(
                cachedFormat: Self.format(sampleRate: 48_000, channels: 1),
                incomingFormat: Self.format(sampleRate: 48_000, channels: 2)
            ) == .rebuild
        )
    }

    @Test func journalConsumerAcceptsSamplesWithoutFailureHandling() {
        #expect(AudioCapture.consumerFailureAction(for: .accepted) == .none)
    }

    @Test func journalConsumerOverflowAndFailureAreEscalated() {
        #expect(AudioCapture.consumerFailureAction(for: .overflow) == .escalate)
        #expect(AudioCapture.consumerFailureAction(for: .failed("disk full")) == .escalate)
    }

    @Test func selectedMicrophoneUsesRawCaptureWhenSuppressionIsRequested() {
        #expect(
            AudioCapture.captureRoute(
                deviceUID: "configured-microphone",
                noiseSuppression: true
            ) == .rawSelectedMicrophoneSuppressionUnavailable
        )
    }

    @Test func systemDefaultUsesVoiceProcessingWhenSuppressionIsRequested() {
        #expect(
            AudioCapture.captureRoute(deviceUID: nil, noiseSuppression: true)
                == .voiceProcessedSystemDefault
        )
    }

    @Test func disabledSuppressionUsesRawCapture() {
        #expect(
            AudioCapture.captureRoute(
                deviceUID: "configured-microphone",
                noiseSuppression: false
            ) == .rawSelectedMicrophone
        )
        #expect(
            AudioCapture.captureRoute(deviceUID: nil, noiseSuppression: false)
                == .rawSystemDefault
        )
    }

    @Test func selectedMicrophoneSuppressionWarningIsTruthfulAndFirst() {
        let route = AudioCapture.captureRoute(
            deviceUID: "configured-microphone",
            noiseSuppression: true
        )
        var warnings: [String] = []
        if let warning = AudioCapture.captureWarning(for: route) {
            warnings = AudioCapture.captureWarnings(warnings, adding: warning)
        }
        warnings = AudioCapture.captureWarnings(
            warnings,
            adding: "Configured microphone not found — using system default"
        )

        #expect(warnings == [
            "Noise suppression is unavailable with a selected microphone — using raw microphone audio",
            "Configured microphone not found — using system default",
        ])
        #expect(
            AudioCapture.captureWarning(for: .voiceProcessedSystemDefault) == nil
        )
        #expect(AudioCapture.captureWarning(for: .rawSystemDefault) == nil)
    }

    @Test func effectiveVoiceProcessingLetsVPIOManageDevices() {
        #expect(AudioCapture.deviceApplicationPolicy(effectiveVoiceProcessing: true) == .systemManaged)
        #expect(AudioCapture.deviceApplicationPolicy(effectiveVoiceProcessing: false) == .applyConfiguredInput)
    }

    @Test func lateVoiceProcessingFailureRetriesOnceWithRawEngine() {
        #expect(AudioCapture.captureFailureAction(effectiveVoiceProcessing: true) == .retryRaw)
        #expect(AudioCapture.captureFailureAction(effectiveVoiceProcessing: false) == .propagate)
    }

    @Test func configuredDeviceVerificationAcceptsMatchingEffectiveDevice() {
        #expect(
            AudioCapture.configuredDeviceVerificationAction(
                expectedDeviceID: 42,
                effectiveDeviceID: 42
            ) == .accept
        )
    }

    @Test func configuredDeviceVerificationAbortsForMismatchedEffectiveDevice() {
        #expect(
            AudioCapture.configuredDeviceVerificationAction(
                expectedDeviceID: 42,
                effectiveDeviceID: 7
            ) == .abortMismatch
        )
    }

    @Test func configuredDeviceVerificationAbortsWhenEffectiveDeviceCannotBeQueried() {
        #expect(
            AudioCapture.configuredDeviceVerificationAction(
                expectedDeviceID: 42,
                effectiveDeviceID: nil
            ) == .abortQueryFailure
        )
    }

    @Test func unchangedStateNeedsNoTransition() {
        #expect(AudioCapture.voiceProcessingAction(requested: true, current: true, transitionFailed: false) == .keepCurrent)
        #expect(AudioCapture.voiceProcessingAction(requested: false, current: false, transitionFailed: false) == .keepCurrent)
        #expect(AudioCapture.voiceProcessingAction(requested: true, current: true, transitionFailed: true) == .keepCurrent)
        #expect(AudioCapture.voiceProcessingAction(requested: false, current: false, transitionFailed: true) == .keepCurrent)
    }

    @Test func differingStateNeedsRequestedTransition() {
        #expect(AudioCapture.voiceProcessingAction(requested: true, current: false, transitionFailed: false) == .setRequested)
        #expect(AudioCapture.voiceProcessingAction(requested: false, current: true, transitionFailed: false) == .setRequested)
    }

    @Test func failedTransitionNeedsFreshRawEngine() {
        #expect(AudioCapture.voiceProcessingAction(requested: true, current: false, transitionFailed: true) == .replaceWithRawEngine)
        #expect(AudioCapture.voiceProcessingAction(requested: false, current: true, transitionFailed: true) == .replaceWithRawEngine)
    }

    @Test func rawCaptureReplacesEngineWhenVoiceProcessingRemainsEnabled() {
        #expect(
            AudioCapture.rawCapturePostconditionAction(
                effectiveVoiceProcessing: true,
                usingReplacementEngine: false
            ) == .replaceEngine
        )
        #expect(
            AudioCapture.rawCapturePostconditionAction(
                effectiveVoiceProcessing: false,
                usingReplacementEngine: true
            ) == .accept
        )
    }

    @Test func rawCaptureAbortsWhenReplacementEngineStillHasVoiceProcessingEnabled() {
        #expect(
            AudioCapture.rawCapturePostconditionAction(
                effectiveVoiceProcessing: true,
                usingReplacementEngine: true
            ) == .abort
        )
    }

    @Test func captureWarningsAccumulateInOrder() {
        let suppressionWarning = "Voice processing unavailable"
        let deviceWarning = "Configured microphone unavailable"

        let first = AudioCapture.captureWarnings([], adding: suppressionWarning)
        let both = AudioCapture.captureWarnings(first, adding: deviceWarning)

        #expect(both == [suppressionWarning, deviceWarning])
    }

    @Test func failedAttemptWarningsRollBackBeforeFallbackWarnings() {
        let existing = ["Warning from before capture attempt"]
        let attemptStart = existing.count
        let withFailedAttemptWarning = AudioCapture.captureWarnings(
            existing,
            adding: "Voice processing used the system microphone"
        )

        let rolledBack = AudioCapture.captureWarnings(
            withFailedAttemptWarning,
            rollingBackTo: attemptStart
        )
        let withFallback = AudioCapture.captureWarnings(
            rolledBack,
            adding: "Voice processing failed — using raw microphone audio"
        )
        let withSuccessfulRawWarning = AudioCapture.captureWarnings(
            withFallback,
            adding: "Configured microphone not found — using system default"
        )

        #expect(withSuccessfulRawWarning == [
            "Warning from before capture attempt",
            "Voice processing failed — using raw microphone audio",
            "Configured microphone not found — using system default",
        ])
    }

    /// The failure Bruno hit on the HD Webcam C615: pinning a 16 kHz device leaves the app's
    /// client scope at 48 kHz and the graph refuses to initialize. Its own message is
    /// "error -10868", so the reason has to name both rates.
    @Test func formatMismatchStartFailureNamesBothRates() {
        let error = NSError(
            domain: "com.apple.coreaudio.avfaudio",
            code: Int(kAudioUnitErr_FormatNotSupported)
        )

        let reason = AudioCapture.engineStartFailureReason(
            error,
            hardware: Self.format(sampleRate: 16_000),
            client: Self.format(sampleRate: 48_000)
        )

        #expect(reason == "macOS refused the microphone's audio format (microphone 16 kHz, app 48 kHz)")
    }

    @Test func otherStartFailuresKeepTheirOwnMessage() {
        let error = NSError(
            domain: "com.apple.coreaudio.avfaudio",
            code: -10875,
            userInfo: [NSLocalizedDescriptionKey: "The audio device was removed."]
        )

        let reason = AudioCapture.engineStartFailureReason(
            error,
            hardware: Self.format(sampleRate: 48_000),
            client: Self.format(sampleRate: 48_000)
        )

        #expect(reason == "The audio device was removed.")
    }

    @Test(arguments: [
        (44_100.0, "44.1 kHz"),
        (48_000.0, "48 kHz"),
        (16_000.0, "16 kHz"),
        (8_000.0, "8 kHz"),
        (960.0, "960 Hz"),
    ])
    func sampleRatesReadAsRates(sampleRate: Double, expected: String) {
        #expect(AudioCapture.rateText(sampleRate) == expected)
    }
}
