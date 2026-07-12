import Testing
@testable import FreeTalker

struct AudioCaptureDecisionTests {
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

    @Test func captureWarningsAccumulateInOrder() {
        let suppressionWarning = "Voice processing unavailable"
        let deviceWarning = "Configured microphone unavailable"

        let first = AudioCapture.captureWarnings([], adding: suppressionWarning)
        let both = AudioCapture.captureWarnings(first, adding: deviceWarning)

        #expect(both == [suppressionWarning, deviceWarning])
    }
}
