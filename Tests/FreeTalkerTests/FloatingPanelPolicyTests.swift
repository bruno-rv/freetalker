import AppKit
import Testing
@testable import FreeTalker

@Suite @MainActor struct FloatingPanelPolicyTests {
    @Test func hudPanelRemainsNonactivatingAndVisibleAcrossSpaces() {
        let panel = HUDController.makePanel(size: NSSize(width: 200, height: 60))

        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.stationary))
        #expect(panel.level == .floating)
        #expect(panel.canBecomeKey == false)
        #expect(panel.canBecomeMain == false)
        #expect(panel.ignoresMouseEvents == false)
        #expect(panel.isMovableByWindowBackground == false)
    }

    @Test func resizeClampsAgainstTheScreenCapturedBeforeTheWindowChangesScreens() {
        let capturedVisibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let adjacentVisibleFrame = CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
        let originalOrigin = CGPoint(x: 100, y: 100)
        let resizedPanelSize = CGSize(width: 300, height: 80)

        let origin = HUDController.resizedOrigin(
            preserving: originalOrigin,
            panelSize: resizedPanelSize,
            capturedVisibleFrame: capturedVisibleFrame
        )
        let wrongScreenOrigin = FloatingPanelGeometry.clampedOrigin(
            originalOrigin,
            panelSize: resizedPanelSize,
            visibleFrame: adjacentVisibleFrame
        )

        #expect(origin == originalOrigin)
        #expect(wrongScreenOrigin != originalOrigin)
    }
}
