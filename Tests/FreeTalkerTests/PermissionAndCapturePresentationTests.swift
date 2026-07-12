import Testing
@testable import FreeTalker

@Suite struct PermissionAndCapturePresentationTests {
    @Test func operationalHotKeyTapOverridesStaleRawInputMonitoringDenial() {
        let presentation = InputMonitoringPermissionPresentation.make(
            rawAuthorized: false,
            hotKeyOperational: true
        )

        #expect(presentation.isOperational)
        #expect(presentation.label == "Input Monitoring and global shortcuts working")
        #expect(!presentation.showsOpenSystemSettings)
    }

    @Test func unavailableHotKeyTapDoesNotPaintPermissionGreen() {
        let presentation = InputMonitoringPermissionPresentation.make(
            rawAuthorized: true,
            hotKeyOperational: false
        )

        #expect(!presentation.isOperational)
        #expect(presentation.label.contains("Global shortcuts unavailable"))
        #expect(presentation.guidance.contains("relaunch"))
    }

    @Test func captureStartFailureProducesVisibleLocalizedMessage() {
        #expect(
            AppCoordinator.captureStartFailureMessage(errorDescription: "No input device")
                == "Could not start recording: No input device"
        )
    }

    @Test func capturedAudioRejectsEmptyAndDeadMicrophoneSignal() {
        #expect(AppCoordinator.capturedAudioIssue(sampleCount: 0, peak: 0, rms: 0) == "No microphone audio detected")
        #expect(AppCoordinator.capturedAudioIssue(sampleCount: 16_000, peak: 0, rms: 0) == "No microphone audio detected")
        #expect(AppCoordinator.capturedAudioIssue(sampleCount: 16_000, peak: 1e-8, rms: 1e-9) == "No microphone audio detected")
    }

    @Test func capturedAudioRejectsNonfiniteMetrics() {
        #expect(AppCoordinator.capturedAudioIssue(sampleCount: 16_000, peak: .nan, rms: 0) == "No microphone audio detected")
        #expect(AppCoordinator.capturedAudioIssue(sampleCount: 16_000, peak: 1, rms: .infinity) == "No microphone audio detected")
    }

    @Test func capturedAudioAllowsQuietAndNormalFiniteSignal() {
        #expect(AppCoordinator.capturedAudioIssue(sampleCount: 16_000, peak: 1e-6, rms: 1e-7) == nil)
        #expect(AppCoordinator.capturedAudioIssue(sampleCount: 16_000, peak: 0.4, rms: 0.05) == nil)
    }
}
