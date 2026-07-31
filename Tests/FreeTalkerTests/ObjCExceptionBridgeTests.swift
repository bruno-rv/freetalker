import Foundation
import ObjCExceptionBridge
import Testing

/// The bridge exists because an NSException unwinding through Swift frames leaves the process in
/// an undefined state — see docs/dictation-zero-audio-crash-2026-07-31.md and
/// `AudioCapture.startCaptureAttempt`.
struct ObjCExceptionBridgeTests {
    @Test func bodyRunsAndReportsSuccessWhenNothingRaises() {
        var ran = false
        var error: NSError?
        let succeeded = FTRunCatchingObjCException({ ran = true }, &error)
        #expect(succeeded)
        #expect(ran)
        #expect(error == nil)
    }

    @Test func raisedExceptionBecomesAnError() {
        var error: NSError?
        let succeeded = FTRunCatchingObjCException({
            NSException(
                name: .invalidArgumentException,
                reason: "required condition is false: format.sampleRate == hwFormat.sampleRate",
                userInfo: nil
            ).raise()
        }, &error)
        #expect(!succeeded)
        #expect(error?.domain == FTObjCExceptionErrorDomain)
        #expect(
            error?.localizedDescription
                == "required condition is false: format.sampleRate == hwFormat.sampleRate"
        )
        #expect(error?.userInfo["FTExceptionName"] as? String == NSExceptionName.invalidArgumentException.rawValue)
    }

    /// Control for the whole point of the bridge: execution continues normally afterwards.
    @Test func executionContinuesAfterAContainedException() {
        var error: NSError?
        _ = FTRunCatchingObjCException({
            NSException(name: .genericException, reason: "boom", userInfo: nil).raise()
        }, &error)
        var ran = false
        let succeeded = FTRunCatchingObjCException({ ran = true }, nil)
        #expect(succeeded)
        #expect(ran)
    }
}
