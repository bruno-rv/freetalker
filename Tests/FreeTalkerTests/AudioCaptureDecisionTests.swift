import Testing
@testable import FreeTalker

struct AudioCaptureDecisionTests {
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
}
