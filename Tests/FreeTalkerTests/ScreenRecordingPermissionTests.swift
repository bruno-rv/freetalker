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
        let missing = ScreenRecordingPermissionPresentation.make(status: .notGranted)
        #expect(missing.label == "Screen Recording not granted")
        #expect(missing.showsRequestAccess)
        #expect(missing.showsOpenSystemSettings)

        let granted = ScreenRecordingPermissionPresentation.make(status: .granted)
        #expect(granted.label == "Screen Recording granted")
        #expect(!granted.showsRequestAccess)
        #expect(!granted.showsOpenSystemSettings)
    }
}
