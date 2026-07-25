import SwiftUI

/// Shared presentation for `PermissionDiagnosisItem` rows — one mapping from `PermissionState`
/// to color and one "Open System Settings" dispatch, reused by both Settings → Privacy
/// (`SettingsView`'s `GeneralSettingsView`) and `FirstRunWalkthroughView` so the two surfaces
/// can never drift into showing different colors/targets for the same state.
enum PermissionDiagnosisPresentation {
    static func color(for state: PermissionState) -> Color {
        switch state {
        case .granted: return .green
        case .denied: return .red
        case .staleGranted: return .orange
        case .notDetermined, .unknown: return .gray
        }
    }

    static func openSystemSettings(for kind: PermissionKind) {
        switch kind {
        case .accessibility: Permissions.openAccessibilitySettings()
        case .microphone: Permissions.openMicrophoneSettings()
        case .inputMonitoring: Permissions.openInputMonitoringSettings()
        }
    }
}
