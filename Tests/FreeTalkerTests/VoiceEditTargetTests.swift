import CoreGraphics
import Foundation
import Testing
@testable import FreeTalker

@MainActor
@Suite struct VoiceEditTargetTests {
    @Test func selectionFingerprintChangesWithSelectedText() {
        let first = SelectionSnapshot.fingerprint(for: "hello")
        #expect(first == SelectionSnapshot.fingerprint(for: "hello"))
        #expect(first != SelectionSnapshot.fingerprint(for: "hello!"))
    }

    @Test func secureAndProtectedFieldsAreRejected() {
        #expect(SystemAccessibilityNodeAdapter.isSecure(role: "AXSecureTextField", protected: false))
        #expect(SystemAccessibilityNodeAdapter.isSecure(role: "AXTextArea", protected: true))
        #expect(!SystemAccessibilityNodeAdapter.isSecure(role: "AXTextArea", protected: false))
    }

    @Test func staleSelectionCannotBeReplaced() {
        let expected = SelectionSnapshot.fingerprint(for: "selected")
        #expect(SelectionAccess.revalidationError(
            appMatches: true,
            elementMatches: true,
            windowMatches: true,
            expectedRange: NSRange(location: 3, length: 8),
            currentRange: NSRange(location: 3, length: 8),
            expectedFingerprint: expected,
            currentText: "changed!"
        ) == .selectionChanged)
        #expect(SelectionAccess.revalidationError(
            appMatches: true,
            elementMatches: true,
            windowMatches: true,
            expectedRange: NSRange(location: 3, length: 8),
            currentRange: NSRange(location: 4, length: 8),
            expectedFingerprint: expected,
            currentText: "selected"
        ) == .selectionChanged)
    }

    @Test func voiceEditHotkeyDispatchIsSynchronousAndSwallowed() {
        let ptt = HotKeyMatcher(spec: .default)
        let redo = HotKeyMatcher(spec: HotKeySpec(modifiers: 0, keyCode: 105))
        let voice = HotKeyMatcher(spec: HotKeySpec(modifiers: 0, keyCode: 107))
        var mutablePTT = ptt
        var mutableRedo: HotKeyMatcher? = redo
        var mutableVoice: HotKeyMatcher? = voice

        let down = HotKeyManager.dispatch(
            kind: .keyDown, keyCode: 107, flags: 0, isAutorepeat: false,
            matcher: &mutablePTT, redoMatcher: &mutableRedo, voiceEditMatcher: &mutableVoice
        )
        #expect(down.voiceEditEngaged)
        #expect(down.swallow)

        let up = HotKeyManager.dispatch(
            kind: .keyUp, keyCode: 107, flags: 0, isAutorepeat: false,
            matcher: &mutablePTT, redoMatcher: &mutableRedo, voiceEditMatcher: &mutableVoice
        )
        #expect(!up.voiceEditEngaged)
        #expect(up.swallow)
    }

    @Test func voiceEditActionRunsBeforeEventTapReturns() {
        var called = false
        let outcome = HotKeyManager.DispatchOutcome(voiceEditEngaged: true, swallow: true)
        HotKeyManager.deliverVoiceEditIfNeeded(outcome: outcome, eventSeconds: 42) { seconds in
            #expect(seconds == 42)
            called = true
        }
        #expect(called)
    }

    @Test func threeHotkeysRejectEveryCollision() {
        let ptt = HotKeySpec.default
        let redo = HotKeySpec(modifiers: 0, keyCode: 105)
        let voice = HotKeySpec(modifiers: 0, keyCode: 107)
        #expect(HotKeySpec.validActionSpec(voice, pttSpec: ptt, otherActionSpec: redo) == voice)
        #expect(HotKeySpec.validActionSpec(redo, pttSpec: ptt, otherActionSpec: redo) == nil)
        #expect(HotKeySpec.validActionSpec(ptt, pttSpec: ptt, otherActionSpec: redo) == nil)
    }

    @Test func voiceEditHotkeyPersistsAndInvalidAssignmentsAreDropped() {
        let suite = "VoiceEditTargetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let voice = HotKeySpec(modifiers: 0, keyCode: 107)

        var settings: AppSettings? = AppSettings(defaults: defaults)
        settings?.voiceEditHotKeySpec = voice
        settings = AppSettings(defaults: defaults)
        #expect(settings?.voiceEditHotKeySpec == voice)

        settings?.redoHotKeySpec = voice
        #expect(settings?.redoHotKeySpec == nil)
        #expect(settings?.voiceEditHotKeySpec == voice)
    }
}
