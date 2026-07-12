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
}
