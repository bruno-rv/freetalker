import Testing
@testable import FreeTalker

@Suite struct ScreenRecordingPermissionTests {
    @Test func resetReconcilesDirectlyFromCurrentPreflight() {
        #expect(Permissions.screenRecordingAuthorization(preflight: { true }) == .granted)
        #expect(Permissions.screenRecordingAuthorization(preflight: { false }) == .notGranted)
    }

    @Test func falseRequestCallsSystemOnceAndRemainsNotGranted() {
        var requestCalls = 0
        let status = Permissions.requestScreenRecording(
            request: { requestCalls += 1; return false },
            preflight: { false }
        )
        #expect(requestCalls == 1)
        #expect(status == .notGranted)
    }

    @Test func settingsPresentationShowsBothActionsOnlyWhenNotGranted() {
        let missing = ScreenRecordingPermissionPresentation.make(status: .notGranted, requestAttempted: false)
        #expect(missing.label == "Screen Recording not granted")
        #expect(missing.showsRequestAccess)
        #expect(missing.showsOpenSystemSettings)

        let pendingRelaunch = ScreenRecordingPermissionPresentation.make(status: .notGranted, requestAttempted: true)
        #expect(pendingRelaunch.label == "Screen Recording not available yet")
        #expect(pendingRelaunch.guidance?.contains("relaunch") == true)
        #expect(!pendingRelaunch.showsRequestAccess)

        let granted = ScreenRecordingPermissionPresentation.make(status: .granted, requestAttempted: true)
        #expect(granted.label == "Screen Recording granted")
        #expect(!granted.showsRequestAccess)
        #expect(!granted.showsOpenSystemSettings)
    }
}
