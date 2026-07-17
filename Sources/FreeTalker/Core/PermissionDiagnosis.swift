import AppKit
import AVFoundation
import Foundation

/// Coordinator-owned model for Permission Diagnosis (PLAN.md F2, CONTEXT.md). Distinguishes "no
/// evidence yet" (`unknown`) from "evidence something is broken" (`staleGranted`/`denied`) —
/// collapsing the two would misdiagnose a permission that simply hasn't been exercised yet as
/// broken. See CONTEXT.md's "Permission Diagnosis" glossary entry.
enum PermissionState: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
    case staleGranted
    case unknown
}

/// Health of the most recently completed microphone capture, independent of TCC authorization.
/// `noSignal` is deliberately NOT `staleGranted`: a muted input, a disconnected device, or a
/// route delivering no live signal says nothing about whether the Microphone permission itself
/// is granted — see the clamshell/webcam-mic lesson (CONTEXT.md "Permission Diagnosis").
enum MicrophoneCaptureHealth: Equatable, Sendable {
    case unknown
    case ok
    case noSignal(route: String?)
}

/// Which System Settings pane / permission an item's "Open System Settings" button targets.
/// Kept as a discrete case rather than switching on `title` text at the call site.
enum PermissionKind: Equatable, Sendable {
    case accessibility
    case microphone
    case inputMonitoring
}

/// One row of the Privacy tab / menu-bar diagnosis presentation.
struct PermissionDiagnosisItem: Equatable, Sendable {
    let kind: PermissionKind
    let title: String
    let state: PermissionState
    let detail: String
    let showsRelaunch: Bool
    let showsOpenSystemSettings: Bool
}

/// Coordinator-owned snapshot of every permission + capture-health signal Permission Diagnosis
/// reasons about. Recomputed on demand (`AppCoordinator.refreshPermissionDiagnosis()`) — never
/// polled (PLAN.md F2.3): app activation, menu open, Privacy tab "Run Diagnosis", and
/// permission-class insertion/capture failures.
struct PermissionDiagnosis: Equatable, Sendable {
    var accessibility: PermissionState = .unknown
    var microphone: PermissionState = .unknown
    var microphoneCaptureHealth: MicrophoneCaptureHealth = .unknown
    var inputMonitoring: PermissionState = .unknown
    var inputMonitoringRequired: Bool = false

    /// Menu-bar badge gate (PLAN.md F2.3): required = Microphone + Accessibility always, Input
    /// Monitoring only when a hotkey is bound. Any required permission `denied`/`staleGranted`
    /// warrants the warning icon; `unknown`/`notDetermined` never do — unknown ≠ broken.
    var requiresWarning: Bool {
        Self.isBroken(accessibility)
            || Self.isBroken(microphone)
            || (inputMonitoringRequired && Self.isBroken(inputMonitoring))
    }

    private static func isBroken(_ state: PermissionState) -> Bool {
        state == .denied || state == .staleGranted
    }

    var items: [PermissionDiagnosisItem] {
        [
            Self.accessibilityItem(accessibility),
            Self.microphoneItem(microphone, captureHealth: microphoneCaptureHealth),
            Self.inputMonitoringItem(inputMonitoring, required: inputMonitoringRequired)
        ]
    }

    // MARK: - Pure state computation (testable without touching TCC/AX/IOHID APIs)

    /// Accessibility's TCC claim (`AXIsProcessTrusted`) vs. actual capability: the same tap
    /// (`HotKeyManager`'s `CGEventTap`) Input Monitoring already reconciles against also
    /// requires Accessibility, so an operational tap is positive evidence Accessibility actually
    /// works. But a dead tap is only provable evidence Accessibility itself is broken when Input
    /// Monitoring's raw TCC claim is ALSO granted — if Input Monitoring is the one actually
    /// denied, that alone fully explains the dead tap and says nothing about Accessibility, so we
    /// report `.unknown` rather than falsely accusing Accessibility of being stale (unknown ≠
    /// broken). AX exposes no `notDetermined` signal distinct from denied — both surface as
    /// `.denied`.
    nonisolated static func accessibilityState(
        rawTrusted: Bool, hotKeyOperational: Bool, inputMonitoringRawAuthorized: Bool
    ) -> PermissionState {
        guard rawTrusted else { return .denied }
        if hotKeyOperational { return .granted }
        return inputMonitoringRawAuthorized ? .staleGranted : .unknown
    }

    /// Input Monitoring: reuses the exact reconciliation `InputMonitoringPermissionPresentation`
    /// already performs (PLAN.md F2.1), recast as a `PermissionState`.
    nonisolated static func inputMonitoringState(rawAuthorized: Bool, hotKeyOperational: Bool) -> PermissionState {
        if hotKeyOperational { return .granted }
        return rawAuthorized ? .staleGranted : .denied
    }

    nonisolated static func microphoneAuthorizationState(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        @unknown default: return .unknown
        }
    }

    /// Any of the four hotkey slots bound. PTT (`pttSpec`) is a non-optional value type, so
    /// "bound" means it carries a non-modifier key or at least one modifier bit; the three
    /// action slots (Insert Last Dictation, Voice Edit, Dictation History Panel) are optional
    /// and "bound" iff non-nil.
    nonisolated static func anyHotKeyBound(
        pttSpec: HotKeySpec,
        insertLastDictationSpec: HotKeySpec?,
        voiceEditSpec: HotKeySpec?,
        historyPanelSpec: HotKeySpec?
    ) -> Bool {
        (pttSpec.keyCode != nil || pttSpec.modifiers != 0)
            || insertLastDictationSpec != nil
            || voiceEditSpec != nil
            || historyPanelSpec != nil
    }

    // MARK: - Presentation

    private static func accessibilityItem(_ state: PermissionState) -> PermissionDiagnosisItem {
        switch state {
        case .granted:
            return PermissionDiagnosisItem(
                kind: .accessibility, title: "Accessibility", state: state, detail: "Working.",
                showsRelaunch: false, showsOpenSystemSettings: false
            )
        case .staleGranted:
            return PermissionDiagnosisItem(
                kind: .accessibility, title: "Accessibility", state: state,
                detail: "System Settings reports Accessibility as granted, but it isn't functioning — this usually follows a rebuild. Relaunching FreeTalker re-establishes it.",
                showsRelaunch: true, showsOpenSystemSettings: false
            )
        case .unknown:
            return PermissionDiagnosisItem(
                kind: .accessibility, title: "Accessibility", state: state,
                detail: "Granted, but global shortcuts aren't working — grant Input Monitoring too, which the shortcut tap also requires.",
                showsRelaunch: false, showsOpenSystemSettings: false
            )
        case .denied, .notDetermined:
            return PermissionDiagnosisItem(
                kind: .accessibility, title: "Accessibility", state: state,
                detail: "Not granted — required for global shortcuts and pasting dictated text.",
                showsRelaunch: false, showsOpenSystemSettings: true
            )
        }
    }

    private static func microphoneItem(
        _ state: PermissionState, captureHealth: MicrophoneCaptureHealth
    ) -> PermissionDiagnosisItem {
        let healthDetail: String
        switch captureHealth {
        case .unknown:
            healthDetail = "No dictation has run yet."
        case .ok:
            healthDetail = "Last capture delivered a signal."
        case .noSignal(let route):
            healthDetail = route.map {
                "Last capture had no signal (\($0)) — check the input device, mute, or connection."
            } ?? "Last capture had no signal — check the input device, mute, or connection."
        }
        switch state {
        case .granted, .staleGranted, .unknown:
            return PermissionDiagnosisItem(
                kind: .microphone, title: "Microphone", state: state, detail: healthDetail,
                showsRelaunch: false, showsOpenSystemSettings: false
            )
        case .notDetermined:
            return PermissionDiagnosisItem(
                kind: .microphone, title: "Microphone", state: state, detail: "Not yet requested.",
                showsRelaunch: false, showsOpenSystemSettings: false
            )
        case .denied:
            return PermissionDiagnosisItem(
                kind: .microphone, title: "Microphone", state: state, detail: "Not granted — required to record dictation.",
                showsRelaunch: false, showsOpenSystemSettings: true
            )
        }
    }

    private static func inputMonitoringItem(_ state: PermissionState, required: Bool) -> PermissionDiagnosisItem {
        guard required else {
            return PermissionDiagnosisItem(
                kind: .inputMonitoring, title: "Input Monitoring", state: .unknown,
                detail: "Not required — no global shortcut is bound.",
                showsRelaunch: false, showsOpenSystemSettings: false
            )
        }
        switch state {
        case .granted:
            return PermissionDiagnosisItem(
                kind: .inputMonitoring, title: "Input Monitoring", state: state, detail: "Global shortcuts working.",
                showsRelaunch: false, showsOpenSystemSettings: false
            )
        case .staleGranted:
            return PermissionDiagnosisItem(
                kind: .inputMonitoring, title: "Input Monitoring", state: state,
                detail: "System Settings reports Input Monitoring as granted, but global shortcuts aren't working — this usually follows a rebuild. Relaunching FreeTalker re-establishes it.",
                showsRelaunch: true, showsOpenSystemSettings: true
            )
        case .denied, .notDetermined, .unknown:
            return PermissionDiagnosisItem(
                kind: .inputMonitoring, title: "Input Monitoring", state: state, detail: "Not granted — required for global shortcuts.",
                showsRelaunch: false, showsOpenSystemSettings: true
            )
        }
    }
}

/// Dedicated relaunch helper for `staleGranted` recovery (PLAN.md F2.2) — deliberately NOT
/// `scripts/self-update.sh` (which pulls git and rebuilds); this only restarts the current
/// bundle so a fresh process re-establishes the capabilities TCC already claims to grant it.
/// Spawns a detached shell that waits for this process to fully exit before running `open -n`,
/// rather than racing `AppInstanceLease`'s own single-instance reconciliation (App.swift).
enum AppRelaunch {
    @MainActor
    static func relaunch(
        bundlePath: String = Bundle.main.bundlePath,
        spawn: (String) -> Void = { path in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "sleep 0.5 && /usr/bin/open -n \"\(path)\""]
            try? process.run()
        },
        terminate: () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        spawn(bundlePath)
        terminate()
    }
}
