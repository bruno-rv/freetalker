import CoreGraphics
import ScreenCaptureKit

struct ActiveWindowCaptureTarget: Sendable {
    let processID: pid_t
    let windowTitle: String?
}

enum ActiveWindowScreenshotError: Error {
    case permissionRequired
    case windowUnavailable
}

protocol ActiveWindowScreenshotCapturing: Sendable {
    func capture(target: ActiveWindowCaptureTarget) async throws -> CGImage
}

struct ActiveWindowScreenshotService: ActiveWindowScreenshotCapturing {
    func capture(target: ActiveWindowCaptureTarget) async throws -> CGImage {
        guard Permissions.isScreenRecordingAuthorized() else {
            throw ActiveWindowScreenshotError.permissionRequired
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let candidates = content.windows.filter { $0.owningApplication?.processID == target.processID }
        let window = candidates.first(where: { $0.title == target.windowTitle }) ?? candidates.first
        guard let window else { throw ActiveWindowScreenshotError.windowUnavailable }

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * 2))
        configuration.height = max(1, Int(window.frame.height * 2))
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration
        )
    }
}
