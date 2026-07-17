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

    // MARK: - Microphone capture-health classification (shared by `stopAndTranscribe` and Voice
    // Edit's `finishVoiceEditInstructionRecording` via `applyCaptureHealth`). See P2 finding:
    // Voice Edit never assigned `microphoneCaptureHealth`, leaving Privacy showing stale health
    // after a silent Voice Edit.

    @Test func captureHealthIsNoSignalWithRouteFailureForASilentCapture() {
        let diagnostics = CaptureDiagnostics(
            peak: 0, rms: 0, inputDeviceUID: "device-1", routeFailure: "input vanished"
        )
        #expect(AppCoordinator.captureHealth(for: diagnostics) == .noSignal(route: "input vanished"))
    }

    @Test func captureHealthIsOKForANormalSignal() {
        let diagnostics = CaptureDiagnostics(
            peak: 0.4, rms: 0.05, inputDeviceUID: "device-1", routeFailure: nil
        )
        #expect(AppCoordinator.captureHealth(for: diagnostics) == .ok)
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

    @Test func shouldSynthesizePasteTreatsNilSnapshotBundleIDAsUnverifiableRegardlessOfPidOrElementMatch() {
        // A non-nil target with no bundle id at all has no verifiable identity — a matching pid
        // alone doesn't prove it (pid reuse), and neither does an `.unavailable` element
        // comparison. Must drift (return false), not fall through to the pid/element checks.
        #expect(Insertion.shouldSynthesizePaste(
            hasTarget: true, snapshotBundleID: nil, currentBundleID: "com.example.current",
            pidMatch: true, elementComparison: .unavailable
        ) == false)
        // Even a current bundle id of nil (matching the snapshot's nil) must not be treated as
        // "identity confirmed" — there is nothing to compare.
        #expect(Insertion.shouldSynthesizePaste(
            hasTarget: true, snapshotBundleID: nil, currentBundleID: nil,
            pidMatch: true, elementComparison: .unavailable
        ) == false)
        // A positive AX element match doesn't rescue a nil-bundle-id snapshot either — the fix
        // is unconditional on bundle id, matching the finding's "nil bundleID or otherwise
        // unverifiable" wording.
        #expect(Insertion.shouldSynthesizePaste(
            hasTarget: true, snapshotBundleID: nil, currentBundleID: "com.example.current",
            pidMatch: true, elementComparison: .match
        ) == false)
    }

    @Test func classifyPreflightFailureTreatsNilSnapshotBundleIDAsTargetDrift() {
        // End-to-end through `classifyPreflightFailure`: the PID-reuse bypass (nil snapshot
        // bundle id + matching pid + unavailable AX comparison) must classify as `.targetDrift`,
        // not fall through to a successful (nil) classification. See Codex finding: nil-bundle-
        // id identity bypass.
        let reason = Insertion.classifyPreflightFailure(
            hasTarget: true, snapshotBundleID: nil, currentBundleID: "com.example.current",
            pidMatch: true, elementComparison: .unavailable,
            hasEditableFocusedElement: true, accessibilityTrusted: true
        )
        #expect(reason == .targetDrift)
    }

    // MARK: - `strict` closes the permissive nil-target branch for the History panel only
    // (Codex finding: unverified panel paste reaching Insertion's permissive nil-target branch)

    @Test func strictModeTreatsANilTargetAsDriftWhileTheDefaultStaysPermissive() {
        // Ordinary dictation (no snapshot at all, e.g. `AppCoordinator.reprocess`) keeps the
        // pre-fix permissive behavior: nothing to contradict, so paste anyway.
        #expect(Insertion.shouldSynthesizePaste(
            hasTarget: false, snapshotBundleID: nil, currentBundleID: "com.example.current"
        ) == true)
        #expect(Insertion.shouldSynthesizePaste(
            hasTarget: false, snapshotBundleID: nil, currentBundleID: "com.example.current", strict: false
        ) == true)
        // The History panel's `strict: true` call site must never fall through to that
        // permissiveness — a nil/unverified target is drift, full stop.
        #expect(Insertion.shouldSynthesizePaste(
            hasTarget: false, snapshotBundleID: nil, currentBundleID: "com.example.current", strict: true
        ) == false)
    }

    @Test func strictModeDoesNotAffectAnAlreadyVerifiedMatchingTarget() {
        // `strict` only closes the nil-target branch — a real, matching, non-drifted target
        // still pastes under strict mode exactly as it would without it.
        #expect(Insertion.shouldSynthesizePaste(
            hasTarget: true, snapshotBundleID: "com.example.app", currentBundleID: "com.example.app",
            pidMatch: true, elementComparison: .match, strict: true
        ) == true)
    }

    @Test func strictModeTreatsAnUnavailableElementComparisonAsDrift() {
        // Matching bundle id + matching pid proves the same APP, not the same focused field. When
        // the element comparison is AX-opaque (`.unavailable`), a same-app focus change between
        // snapshot and paste can't be ruled out. Non-strict (ordinary dictation) keeps pasting —
        // it has no better signal — but `strict` (the History panel replaying old text into
        // whatever is frontmost now) must refuse. See P1 finding.
        #expect(Insertion.shouldSynthesizePaste(
            hasTarget: true, snapshotBundleID: "com.example.app", currentBundleID: "com.example.app",
            pidMatch: true, elementComparison: .unavailable, strict: false
        ) == true)
        #expect(Insertion.shouldSynthesizePaste(
            hasTarget: true, snapshotBundleID: "com.example.app", currentBundleID: "com.example.app",
            pidMatch: true, elementComparison: .unavailable, strict: true
        ) == false)
    }

    @Test func classifyPreflightFailureUnderStrictModeReportsDriftForUnavailableElementIdentity() {
        // End-to-end through `classifyPreflightFailure`: matching bundle/pid but an `.unavailable`
        // element comparison under strict mode is `.targetDrift` (manual paste), never a
        // successful (nil) classification.
        let reason = Insertion.classifyPreflightFailure(
            hasTarget: true, snapshotBundleID: "com.example.app", currentBundleID: "com.example.app",
            pidMatch: true, elementComparison: .unavailable,
            hasEditableFocusedElement: true, accessibilityTrusted: true, strict: true
        )
        #expect(reason == .targetDrift)
        // Same inputs, non-strict: still proceeds (nil = no preflight failure).
        #expect(Insertion.classifyPreflightFailure(
            hasTarget: true, snapshotBundleID: "com.example.app", currentBundleID: "com.example.app",
            pidMatch: true, elementComparison: .unavailable,
            hasEditableFocusedElement: true, accessibilityTrusted: true, strict: false
        ) == nil)
    }

    @Test func classifyPreflightFailureUnderStrictModeReportsTargetDriftForANilTarget() {
        // End-to-end through `classifyPreflightFailure`: the panel's strict nil-target case
        // classifies as `.targetDrift` (posted = false, manual-paste HUD messaging), never as a
        // successful (nil) classification.
        let reason = Insertion.classifyPreflightFailure(
            hasTarget: false, snapshotBundleID: nil, currentBundleID: "com.example.current",
            pidMatch: true, elementComparison: .unavailable,
            hasEditableFocusedElement: true, accessibilityTrusted: true, strict: true
        )
        #expect(reason == .targetDrift)
    }

    @Test func insertWithStrictAndNoTargetLeavesTextOnThePasteboardInsteadOfPasting() {
        // Exercises the real `Insertion.insert` end to end: the History panel's call shape (no
        // target, `strict: true`) must report `.targetDrift`/`posted == false` — the manual-
        // paste flow — never an unverified synthetic paste, regardless of this process's own
        // Accessibility/AX-trust state.
        let outcome = Insertion.insert("Panel strict-mode test text", target: nil, strict: true)
        #expect(outcome == .failure(.targetDrift))
        #expect(!outcome.isPermissionClassFailure)
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

    // MARK: - AppRelaunch argument construction (Codex finding: relaunch command injection)

    @Test func openArgumentsIsAnArgvArrayNeverAShellString() {
        // No shell is ever consulted — a path containing shell metacharacters must stay a single
        // inert argv element, never be parsed/executed as command syntax.
        #expect(AppRelaunch.openArguments(bundlePath: "/Applications/FreeTalker.app") == ["-n", "/Applications/FreeTalker.app"])
    }

    @Test func openArgumentsKeepsACraftedInstallPathAsASingleInertArgument() {
        let crafted = "/tmp/evil\"; rm -rf ~ #.app"
        let arguments = AppRelaunch.openArguments(bundlePath: crafted)
        #expect(arguments.count == 2)
        #expect(arguments[0] == "-n")
        #expect(arguments[1] == crafted)

        let commandSubstitution = "/tmp/$(rm -rf ~).app"
        let arguments2 = AppRelaunch.openArguments(bundlePath: commandSubstitution)
        #expect(arguments2 == ["-n", commandSubstitution])
    }

    @Test @MainActor func relaunchSpawnsWithTheBundlePathThenTerminates() {
        var spawnedPath: String?
        var terminated = false
        AppRelaunch.relaunch(
            bundlePath: "/Applications/FreeTalker.app",
            spawn: { path in spawnedPath = path },
            terminate: { terminated = true }
        )
        #expect(spawnedPath == "/Applications/FreeTalker.app")
        #expect(terminated)
    }
}
