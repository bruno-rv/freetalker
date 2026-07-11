import CoreGraphics
import Foundation
import Testing
@testable import FreeTalker

@Suite struct ActiveWindowScreenshotServiceTests {
    @Test func samePIDMultipleWindowsSelectsOnlyExactWindowID() async throws {
        let backend = FakeScreenshotBackend(windows: [
            .init(windowID: 10, processID: 41),
            .init(windowID: 20, processID: 41)
        ])
        let service = ActiveWindowScreenshotService(authorization: { .granted }, backend: backend)

        _ = try await service.capture(target: .init(appName: nil, bundleID: nil, processID: 41, windowID: 20, windowTitle: nil))

        #expect(backend.capturedIDs == [20])
    }

    @Test func targetSwitchBeforeShareableContentResponseDoesNotFallback() async {
        let backend = FakeScreenshotBackend(windows: [.init(windowID: 99, processID: 41)])
        let service = ActiveWindowScreenshotService(authorization: { .granted }, backend: backend)

        await #expect(throws: ActiveWindowScreenshotError.targetUnavailable) {
            _ = try await service.capture(target: .init(appName: nil, bundleID: nil, processID: 41, windowID: 20, windowTitle: "same"))
        }
        #expect(backend.capturedIDs.isEmpty)
    }

    @Test func notGrantedStaysTyped() async {
        let service = ActiveWindowScreenshotService(authorization: { .notGranted }, backend: FakeScreenshotBackend(windows: []))
        await #expect(throws: ActiveWindowScreenshotError.permissionNotGranted) {
            _ = try await service.capture(target: .init(appName: nil, bundleID: nil, processID: 41, windowID: 20, windowTitle: nil))
        }
    }

    @Test func missingSnapshottedWindowIDIsTargetUnavailable() async {
        let service = ActiveWindowScreenshotService(authorization: { .granted }, backend: FakeScreenshotBackend(windows: []))
        await #expect(throws: ActiveWindowScreenshotError.targetUnavailable) {
            _ = try await service.capture(target: .init(appName: nil, bundleID: nil, processID: 41, windowID: nil, windowTitle: nil))
        }
    }

    @Test func shareableContentFailureStaysTyped() async {
        let backend = FakeScreenshotBackend(windows: [], failListing: true)
        let service = ActiveWindowScreenshotService(authorization: { .granted }, backend: backend)
        await #expect(throws: ActiveWindowScreenshotError.captureFailed) {
            _ = try await service.capture(target: .init(appName: nil, bundleID: nil, processID: 41, windowID: 20, windowTitle: nil))
        }
    }
}

private final class FakeScreenshotBackend: ActiveWindowScreenshotBackend, @unchecked Sendable {
    let windows: [ScreenshotWindow]
    let failListing: Bool
    private(set) var capturedIDs: [CGWindowID] = []
    init(windows: [ScreenshotWindow], failListing: Bool = false) {
        self.windows = windows
        self.failListing = failListing
    }
    func shareableWindows() async throws -> [ScreenshotWindow] {
        if failListing { throw TestError.failed }
        return windows
    }
    func capture(window: ScreenshotWindow) async throws -> CGImage {
        capturedIDs.append(window.windowID)
        return CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 1,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: CGDataProvider(data: Data([0]) as CFData)!,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}

private enum TestError: Error { case failed }
