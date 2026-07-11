import CoreGraphics
import ScreenCaptureKit

enum ScreenRecordingAuthorization: Equatable, Sendable {
    case granted
    case notGranted
}

enum ActiveWindowScreenshotError: Error, Equatable {
    case permissionNotGranted
    case targetUnavailable
    case captureFailed
}

final class ScreenshotWindow: @unchecked Sendable {
    let windowID: CGWindowID
    let processID: pid_t
    fileprivate let scWindow: SCWindow?

    init(windowID: CGWindowID, processID: pid_t, scWindow: SCWindow? = nil) {
        self.windowID = windowID
        self.processID = processID
        self.scWindow = scWindow
    }
}

protocol ActiveWindowScreenshotBackend: Sendable {
    func shareableWindows() async throws -> [ScreenshotWindow]
    func capture(window: ScreenshotWindow) async throws -> CGImage
}

private struct ScreenCaptureKitScreenshotBackend: ActiveWindowScreenshotBackend {
    func shareableWindows() async throws -> [ScreenshotWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.windows.compactMap { window in
            guard let pid = window.owningApplication?.processID else { return nil }
            return ScreenshotWindow(windowID: window.windowID, processID: pid, scWindow: window)
        }
    }

    func capture(window: ScreenshotWindow) async throws -> CGImage {
        guard let scWindow = window.scWindow else { throw ActiveWindowScreenshotError.targetUnavailable }
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(scWindow.frame.width * 2))
        configuration.height = max(1, Int(scWindow.frame.height * 2))
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: scWindow),
            configuration: configuration
        )
    }
}

protocol ActiveWindowScreenshotCapturing: Sendable {
    func capture(target: ContextTargetSnapshot) async throws -> CGImage
}

struct ActiveWindowScreenshotService: ActiveWindowScreenshotCapturing {
    private let authorization: @Sendable () -> ScreenRecordingAuthorization
    private let backend: any ActiveWindowScreenshotBackend

    init(
        authorization: @escaping @Sendable () -> ScreenRecordingAuthorization = { Permissions.screenRecordingAuthorization() },
        backend: any ActiveWindowScreenshotBackend = ScreenCaptureKitScreenshotBackend()
    ) {
        self.authorization = authorization
        self.backend = backend
    }

    func capture(target: ContextTargetSnapshot) async throws -> CGImage {
        switch authorization() {
        case .notGranted: throw ActiveWindowScreenshotError.permissionNotGranted
        case .granted: break
        }
        guard let targetWindowID = target.windowID else { throw ActiveWindowScreenshotError.targetUnavailable }
        let windows: [ScreenshotWindow]
        do {
            windows = try await backend.shareableWindows()
        } catch {
            throw ActiveWindowScreenshotError.captureFailed
        }
        guard let window = windows.first(where: {
            $0.windowID == targetWindowID && $0.processID == target.processID
        }) else {
            throw ActiveWindowScreenshotError.targetUnavailable
        }
        do {
            return try await backend.capture(window: window)
        } catch let error as ActiveWindowScreenshotError {
            throw error
        } catch {
            throw ActiveWindowScreenshotError.captureFailed
        }
    }
}
