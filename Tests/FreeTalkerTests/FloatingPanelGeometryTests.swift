import CoreGraphics
import Testing
@testable import FreeTalker

struct FloatingPanelGeometryTests {
    private let screen = CGRect(x: 100, y: 200, width: 1200, height: 800)
    private let launcherSize = CGSize(width: 180, height: 44)

    @Test(arguments: LauncherEdge.allCases)
    func launcherFrameStaysVisible(edge: LauncherEdge) {
        let frame = FloatingPanelGeometry.launcherFrame(
            edge: edge,
            position: 0.5,
            panelSize: launcherSize,
            visibleFrame: screen
        )

        #expect(screen.contains(frame))
    }

    @Test(arguments: [LauncherEdge.left, .right])
    func verticalLauncherEdgesMapBottomToTop(edge: LauncherEdge) {
        let bottom = FloatingPanelGeometry.launcherFrame(
            edge: edge, position: 0, panelSize: launcherSize, visibleFrame: screen
        )
        let midpoint = FloatingPanelGeometry.launcherFrame(
            edge: edge, position: 0.5, panelSize: launcherSize, visibleFrame: screen
        )
        let top = FloatingPanelGeometry.launcherFrame(
            edge: edge, position: 1, panelSize: launcherSize, visibleFrame: screen
        )

        #expect(bottom.minY == screen.minY)
        #expect(midpoint.midY == screen.midY)
        #expect(top.maxY == screen.maxY)
        #expect(edge == .left ? bottom.minX == screen.minX : bottom.maxX == screen.maxX)
    }

    @Test(arguments: [LauncherEdge.bottom, .top])
    func horizontalLauncherEdgesMapLeftToRight(edge: LauncherEdge) {
        let left = FloatingPanelGeometry.launcherFrame(
            edge: edge, position: 0, panelSize: launcherSize, visibleFrame: screen
        )
        let midpoint = FloatingPanelGeometry.launcherFrame(
            edge: edge, position: 0.5, panelSize: launcherSize, visibleFrame: screen
        )
        let right = FloatingPanelGeometry.launcherFrame(
            edge: edge, position: 1, panelSize: launcherSize, visibleFrame: screen
        )

        #expect(left.minX == screen.minX)
        #expect(midpoint.midX == screen.midX)
        #expect(right.maxX == screen.maxX)
        #expect(edge == .bottom ? left.minY == screen.minY : left.maxY == screen.maxY)
    }

    @Test func launcherPositionClampsAtEndpoints() {
        let below = FloatingPanelGeometry.launcherFrame(
            edge: .left, position: -1, panelSize: launcherSize, visibleFrame: screen
        )
        let above = FloatingPanelGeometry.launcherFrame(
            edge: .top, position: 2, panelSize: launcherSize, visibleFrame: screen
        )

        #expect(below.origin == CGPoint(x: screen.minX, y: screen.minY))
        #expect(above.maxX == screen.maxX)
        #expect(above.maxY == screen.maxY)
    }

    @Test func normalizationRoundTripsOnDisplayWithNonzeroOrigin() {
        let display = DisplayFrame(id: "secondary", visibleFrame: screen)
        let panelSize = CGSize(width: 320, height: 80)
        let frame = CGRect(x: 320, y: 560, width: panelSize.width, height: panelSize.height)

        let saved = FloatingPanelGeometry.normalizedOrigin(frame: frame, display: display)
        let restored = FloatingPanelGeometry.restoredOrigin(
            saved: saved, displays: [display], fallback: display, panelSize: panelSize
        )

        #expect(restored == frame.origin)
        #expect(saved.displayID == display.id)
    }

    @Test func normalizedMidpointRemainsCenteredAfterContentResize() {
        let display = DisplayFrame(id: "main", visibleFrame: screen)
        let original = CGRect(x: 610, y: 578, width: 180, height: 44)
        let saved = FloatingPanelGeometry.normalizedOrigin(frame: original, display: display)

        let restored = FloatingPanelGeometry.restoredOrigin(
            saved: saved,
            displays: [display],
            fallback: display,
            panelSize: CGSize(width: 320, height: 80)
        )

        #expect(restored == CGPoint(x: 540, y: 560))
    }

    @Test func matchingSavedDisplayIsPreferred() {
        let fallback = DisplayFrame(
            id: "main", visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let secondary = DisplayFrame(
            id: "secondary", visibleFrame: CGRect(x: 900, y: 100, width: 1000, height: 700)
        )
        let saved = NormalizedWindowPosition(displayID: "secondary", x: 1, y: 1)

        let origin = FloatingPanelGeometry.restoredOrigin(
            saved: saved,
            displays: [secondary],
            fallback: fallback,
            panelSize: CGSize(width: 300, height: 100)
        )

        #expect(origin == CGPoint(x: 1600, y: 700))
    }

    @Test func missingDisplayFallsBackAndClamps() {
        let fallback = DisplayFrame(
            id: "current",
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let saved = NormalizedWindowPosition(displayID: "gone", x: 1, y: 1)

        let origin = FloatingPanelGeometry.restoredOrigin(
            saved: saved,
            displays: [],
            fallback: fallback,
            panelSize: CGSize(width: 320, height: 80)
        )

        #expect(origin.x <= 480)
        #expect(origin.y <= 520)
    }

    @Test func missingSavedPositionUsesFallbackOrigin() {
        let fallback = DisplayFrame(
            id: "current", visibleFrame: CGRect(x: 100, y: 200, width: 800, height: 600)
        )

        let origin = FloatingPanelGeometry.restoredOrigin(
            saved: nil,
            displays: [],
            fallback: fallback,
            panelSize: CGSize(width: 320, height: 80)
        )

        #expect(origin == fallback.visibleFrame.origin)
    }

    @Test func oversizedHUDKeepsMinimumDraggableAreaVisible() {
        let visibleFrame = CGRect(x: 100, y: 200, width: 200, height: 100)
        let panelSize = CGSize(width: 400, height: 240)

        let low = FloatingPanelGeometry.clampedOrigin(
            CGPoint(x: -1000, y: -1000), panelSize: panelSize, visibleFrame: visibleFrame
        )
        let high = FloatingPanelGeometry.clampedOrigin(
            CGPoint(x: 1000, y: 1000), panelSize: panelSize, visibleFrame: visibleFrame
        )

        #expect(low == CGPoint(x: -252, y: -8))
        #expect(high == CGPoint(x: 252, y: 268))
    }
}
