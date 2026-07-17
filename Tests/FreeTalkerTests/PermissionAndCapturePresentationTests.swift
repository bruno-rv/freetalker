import AVFoundation
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
        #expect(AppCoordinator.capturedAudioIssue(sampleCount: 0, peak: 0, rms: 0) == "Recording failed — no microphone audio was captured")
        #expect(AppCoordinator.capturedAudioIssue(sampleCount: 16_000, peak: 0, rms: 0) == "Recording failed — no microphone audio was captured")
        #expect(AppCoordinator.capturedAudioIssue(sampleCount: 16_000, peak: 1e-8, rms: 1e-9) == "Recording failed — no microphone audio was captured")
    }

    @Test func capturedAudioRejectsNonfiniteMetrics() {
        #expect(AppCoordinator.capturedAudioIssue(sampleCount: 16_000, peak: .nan, rms: 0) == "Recording failed — no microphone audio was captured")
        #expect(AppCoordinator.capturedAudioIssue(sampleCount: 16_000, peak: 1, rms: .infinity) == "Recording failed — no microphone audio was captured")
    }

    @Test func capturedAudioAllowsQuietAndNormalFiniteSignal() {
        #expect(AppCoordinator.capturedAudioIssue(sampleCount: 16_000, peak: 1e-6, rms: 1e-7) == nil)
        #expect(AppCoordinator.capturedAudioIssue(sampleCount: 16_000, peak: 0.4, rms: 0.05) == nil)
    }

    // MARK: - PLAN.md F2: Permission Diagnosis state model

    @Test func accessibilityTrustedButTapDeadIsStaleGrantedOnlyWhenInputMonitoringAlsoClaimsGranted() {
        // Both TCC claims say "granted" yet the tap is dead — that's provable evidence
        // Accessibility itself is broken (the classic post-rebuild stale-signature symptom).
        #expect(
            PermissionDiagnosis.accessibilityState(
                rawTrusted: true, hotKeyOperational: false, inputMonitoringRawAuthorized: true
            ) == .staleGranted
        )
    }

    @Test func accessibilityTrustedTapDeadButInputMonitoringDeniedIsUnknownNotStaleGranted() {
        // The dead tap is fully explained by Input Monitoring being denied — that alone would
        // kill the tap regardless of Accessibility's real state, so Accessibility must not be
        // misdiagnosed as stale (unknown ≠ broken; see CONTEXT.md).
        #expect(
            PermissionDiagnosis.accessibilityState(
                rawTrusted: true, hotKeyOperational: false, inputMonitoringRawAuthorized: false
            ) == .unknown
        )
    }

    @Test func accessibilityTrustedAndTapOperationalIsGranted() {
        #expect(
            PermissionDiagnosis.accessibilityState(
                rawTrusted: true, hotKeyOperational: true, inputMonitoringRawAuthorized: false
            ) == .granted
        )
        #expect(
            PermissionDiagnosis.accessibilityState(
                rawTrusted: true, hotKeyOperational: true, inputMonitoringRawAuthorized: true
            ) == .granted
        )
    }

    @Test func accessibilityNotTrustedIsDeniedRegardlessOfTapOrInputMonitoring() {
        #expect(
            PermissionDiagnosis.accessibilityState(
                rawTrusted: false, hotKeyOperational: false, inputMonitoringRawAuthorized: false
            ) == .denied
        )
        #expect(
            PermissionDiagnosis.accessibilityState(
                rawTrusted: false, hotKeyOperational: true, inputMonitoringRawAuthorized: true
            ) == .denied
        )
    }

    @Test func inputMonitoringReconciliationMatchesStaleVsDeniedVsGranted() {
        #expect(PermissionDiagnosis.inputMonitoringState(rawAuthorized: true, hotKeyOperational: false) == .staleGranted)
        #expect(PermissionDiagnosis.inputMonitoringState(rawAuthorized: false, hotKeyOperational: false) == .denied)
        #expect(PermissionDiagnosis.inputMonitoringState(rawAuthorized: false, hotKeyOperational: true) == .granted)
    }

    @Test func microphoneAuthorizationStateMapsEveryCase() {
        #expect(PermissionDiagnosis.microphoneAuthorizationState(.notDetermined) == .notDetermined)
        #expect(PermissionDiagnosis.microphoneAuthorizationState(.authorized) == .granted)
        #expect(PermissionDiagnosis.microphoneAuthorizationState(.denied) == .denied)
        #expect(PermissionDiagnosis.microphoneAuthorizationState(.restricted) == .denied)
    }

    @Test func microphoneSilenceIsCaptureHealthNoSignalNeverStaleGranted() {
        var diagnosis = PermissionDiagnosis()
        diagnosis.accessibility = .granted
        diagnosis.microphone = .granted
        diagnosis.microphoneCaptureHealth = .noSignal(route: "input vanished")

        // Silence is a capture-health fact, not a permission fact — the Microphone permission
        // state itself stays `.granted` (never coerced to `.staleGranted` by a muted/disconnected
        // device), and a granted-but-silent mic must not raise the menu-bar warning.
        #expect(diagnosis.microphone == .granted)
        #expect(!diagnosis.requiresWarning)
    }

    @Test func unknownCaptureHealthAndUnknownPermissionAreNeverTreatedAsBroken() {
        var diagnosis = PermissionDiagnosis()
        diagnosis.accessibility = .granted
        diagnosis.microphone = .granted
        diagnosis.microphoneCaptureHealth = .unknown
        diagnosis.inputMonitoring = .unknown
        diagnosis.inputMonitoringRequired = true

        #expect(!diagnosis.requiresWarning)
    }

    @Test func badgeRequiresWarningOnlyForRequiredBrokenPermissions() {
        var diagnosis = PermissionDiagnosis()
        diagnosis.accessibility = .granted
        diagnosis.microphone = .granted
        diagnosis.inputMonitoring = .denied
        diagnosis.inputMonitoringRequired = false
        #expect(!diagnosis.requiresWarning, "Input Monitoring denied but not required must not badge")

        diagnosis.inputMonitoringRequired = true
        #expect(diagnosis.requiresWarning, "Input Monitoring denied AND required must badge")
    }

    @Test func badgeAlwaysRequiresMicAndAccessibilityRegardlessOfHotkeyBinding() {
        var diagnosis = PermissionDiagnosis()
        diagnosis.accessibility = .staleGranted
        diagnosis.microphone = .granted
        diagnosis.inputMonitoringRequired = false
        #expect(diagnosis.requiresWarning, "Accessibility is always-required, independent of Input Monitoring's conditionality")
    }

    @Test func anyHotKeyBoundIsFalseOnlyWhenAllFourSlotsAreUnbound() {
        let unboundPTT = HotKeySpec(modifiers: 0, keyCode: nil)
        #expect(!PermissionDiagnosis.anyHotKeyBound(
            pttSpec: unboundPTT, insertLastDictationSpec: nil, voiceEditSpec: nil, historyPanelSpec: nil
        ))
        #expect(PermissionDiagnosis.anyHotKeyBound(
            pttSpec: .default, insertLastDictationSpec: nil, voiceEditSpec: nil, historyPanelSpec: nil
        ))
        #expect(PermissionDiagnosis.anyHotKeyBound(
            pttSpec: unboundPTT,
            insertLastDictationSpec: HotKeySpec(modifiers: 0, keyCode: 9),
            voiceEditSpec: nil, historyPanelSpec: nil
        ))
        #expect(PermissionDiagnosis.anyHotKeyBound(
            pttSpec: unboundPTT, insertLastDictationSpec: nil,
            voiceEditSpec: nil, historyPanelSpec: HotKeySpec(modifiers: 0, keyCode: 3)
        ))
    }

    // MARK: - PLAN.md F2.4: Insertion failure-reason classification

    @Test func onlyAxDeniedIsAPermissionClassFailure() {
        #expect(InsertionOutcome.failure(.axDenied).isPermissionClassFailure)
        #expect(!InsertionOutcome.failure(.targetDrift).isPermissionClassFailure)
        #expect(!InsertionOutcome.failure(.noFocusedElement).isPermissionClassFailure)
        #expect(!InsertionOutcome.failure(.pasteFailed).isPermissionClassFailure)
        #expect(!InsertionOutcome.success.isPermissionClassFailure)
    }

    @Test func classifyPreflightFailureReportsTargetDriftBeforeConsultingAccessibility() {
        // Drift is decided by `shouldSynthesizePaste` alone — accessibility trust must not
        // change the outcome once identity has already drifted.
        let reason = Insertion.classifyPreflightFailure(
            hasTarget: true, snapshotBundleID: "com.example.snapshot", currentBundleID: "com.example.other",
            pidMatch: true, elementComparison: .unavailable,
            hasEditableFocusedElement: true, accessibilityTrusted: true
        )
        #expect(reason == .targetDrift)
    }

    @Test func classifyPreflightFailureDistinguishesAxDeniedFromGenuinelyEmptyFocus() {
        let axDenied = Insertion.classifyPreflightFailure(
            hasTarget: false, snapshotBundleID: nil, currentBundleID: "com.example.current",
            pidMatch: true, elementComparison: .unavailable,
            hasEditableFocusedElement: false, accessibilityTrusted: false
        )
        #expect(axDenied == .axDenied)

        let noFocusedElement = Insertion.classifyPreflightFailure(
            hasTarget: false, snapshotBundleID: nil, currentBundleID: "com.example.current",
            pidMatch: true, elementComparison: .unavailable,
            hasEditableFocusedElement: false, accessibilityTrusted: true
        )
        #expect(noFocusedElement == .noFocusedElement)
    }

    @Test func classifyPreflightFailureReturnsNilWhenPasteShouldProceed() {
        let reason = Insertion.classifyPreflightFailure(
            hasTarget: false, snapshotBundleID: nil, currentBundleID: "com.example.current",
            pidMatch: true, elementComparison: .unavailable,
            hasEditableFocusedElement: true, accessibilityTrusted: true
        )
        #expect(reason == nil)
    }

    @Test func insertReportsTargetDriftForAMismatchedBundleIDRegardlessOfEnvironment() {
        // Exercises the real `Insertion.insert` end to end: a target snapshotted against a
        // bundle ID that cannot possibly be the live frontmost app is a deterministic drift
        // case independent of this process's own Accessibility/AX-trust state, unlike the
        // axDenied/noFocusedElement distinction above (which needs a live AX environment).
        let target = InsertionTarget(
            bundleID: "org.freetalker.does-not-exist.\(UUID().uuidString)",
            pid: -1, focusedElement: nil, window: nil
        )
        let outcome = Insertion.insert("Permission Diagnosis test text", target: target)
        #expect(outcome == .failure(.targetDrift))
        #expect(!outcome.isPermissionClassFailure)
    }
}
