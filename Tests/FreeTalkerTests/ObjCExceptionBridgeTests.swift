import AVFoundation
import Foundation
import ObjCExceptionBridge
import Testing

/// The bridge exists because an NSException raised by `installTap` and unwound through Swift
/// frames leaves the process in an undefined state — see
/// docs/dictation-zero-audio-crash-2026-07-31.md and `AudioCapture.startCaptureAttempt`.
///
/// These exercise the real `installTapOnBus:` call, not a stand-in closure: the whole point of the
/// typed wrapper is that no Swift frame sits between the raise and the `@catch`. The raise is
/// provoked by installing a second tap on a bus that already has one ("required condition is
/// false: nullptr == Tap()") rather than by the format mismatch from the incident, because that
/// one needs specific input hardware while this one is deterministic everywhere.
struct ObjCExceptionBridgeTests {
    @Test func tapInstallsAndReportsSuccess() {
        let engine = AVAudioEngine()
        let node = engine.mainMixerNode
        var error: NSError?
        let installed = FTInstallTapCatchingException(node, 0, 1024, nil, { _, _ in }, &error)
        #expect(installed)
        #expect(error == nil)
        node.removeTap(onBus: 0)
    }

    @Test func raisedExceptionBecomesAnErrorInsteadOfEscaping() {
        let engine = AVAudioEngine()
        let node = engine.mainMixerNode
        #expect(FTInstallTapCatchingException(node, 0, 1024, nil, { _, _ in }, nil))

        var error: NSError?
        let installed = FTInstallTapCatchingException(node, 0, 1024, nil, { _, _ in }, &error)
        #expect(!installed)
        #expect(error?.domain == FTObjCExceptionErrorDomain)
        #expect(error?.localizedDescription.isEmpty == false)
        #expect(error?.userInfo["FTExceptionName"] as? String != nil)
        // The graph that raised is abandoned here, per the bridge's contract — no `removeTap`,
        // no reuse. `AudioCapture` does the same thing with the engine it was using.
    }

    /// The reason the containment matters: the process carries on normally afterwards. A caught
    /// exception says nothing good about the engine that raised, so recovery means a fresh one —
    /// which is exactly what `AudioCapture.startCaptureAttempt`'s `catch` does.
    @Test func aFreshEngineWorksAfterAContainedException() {
        let raisedEngine = AVAudioEngine()
        var error: NSError?
        _ = FTInstallTapCatchingException(raisedEngine.mainMixerNode, 0, 1024, nil, { _, _ in }, nil)
        _ = FTInstallTapCatchingException(raisedEngine.mainMixerNode, 0, 1024, nil, { _, _ in }, &error)
        #expect(error != nil)

        let replacement = AVAudioEngine()
        var secondError: NSError?
        let installed = FTInstallTapCatchingException(
            replacement.mainMixerNode, 0, 1024, nil, { _, _ in }, &secondError
        )
        #expect(installed)
        #expect(secondError == nil)
        replacement.mainMixerNode.removeTap(onBus: 0)
    }
}
