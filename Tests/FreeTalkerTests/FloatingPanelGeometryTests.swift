import AppKit
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

    @Test func legacyLauncherPositionMigratesToSavedPositionOnTheVisibleFrame() {
        let display = DisplayFrame(id: "main", visibleFrame: screen)

        let saved = FloatingPanelGeometry.legacyLauncherPosition(
            edge: .bottom,
            position: 0.25,
            panelSize: launcherSize,
            display: display
        )

        #expect(saved == NormalizedWindowPosition(displayID: "main", x: 0.25, y: 0))
    }

    @Test func restoredOriginKeepsPanelsInsideTheUsableFrame() {
        let display = DisplayFrame(id: "main", visibleFrame: screen)
        let origin = FloatingPanelGeometry.restoredOrigin(
            saved: NormalizedWindowPosition(displayID: "main", x: 1, y: 1),
            displays: [display],
            fallback: display,
            panelSize: launcherSize
        )

        #expect(screen.contains(CGRect(origin: origin, size: launcherSize)))
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

    @Test func contentResizeKeepsNormallySizedPanelInsideTheUsableFrame() {
        let visibleFrame = CGRect(x: 100, y: 200, width: 600, height: 400)

        let origin = FloatingPanelGeometry.clampedOrigin(
            CGPoint(x: 690, y: 590),
            panelSize: CGSize(width: 240, height: 100),
            visibleFrame: visibleFrame
        )

        #expect(origin == CGPoint(x: 460, y: 500))
        #expect(origin != CGPoint(x: 280, y: 350))
    }

    @Test func visibleDockAndMenuBarRemainExcludedFromPlacement() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let visibleFrame = CGRect(x: 0, y: 70, width: 1_440, height: 806)

        let placementFrame = FloatingPanelPlacementPolicy.usableFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            presentationOptions: []
        )

        #expect(placementFrame == visibleFrame)
    }

    @Test(arguments: [
        NSApplication.PresentationOptions.autoHideDock,
        .hideDock
    ])
    func hiddenDockUsesPhysicalScreenBottomWhileStillExcludingMenuBar(
        presentationOptions: NSApplication.PresentationOptions
    ) {
        let screenFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let visibleFrame = CGRect(x: 0, y: 70, width: 1_440, height: 806)

        let placementFrame = FloatingPanelPlacementPolicy.usableFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            presentationOptions: presentationOptions
        )

        #expect(placementFrame == CGRect(x: 0, y: 0, width: 1_440, height: 876))
    }

    @Test func launcherRerenderDuringDragKeepsTheLivePanelOrigin() {
        let dragState = FloatingPanelDragState()
        let liveOrigin = CGPoint(x: 410, y: 30)
        let staleSavedOrigin = CGPoint(x: 80, y: 140)
        var persistedOrigin: CGPoint?

        dragState.begin()
        let renderOrigin = dragState.originForRender(
            liveOrigin: liveOrigin,
            restoredOrigin: staleSavedOrigin
        )
        dragState.finish { persistedOrigin = renderOrigin }

        #expect(renderOrigin == liveOrigin)
        #expect(persistedOrigin == liveOrigin)
        #expect(!dragState.isDragging)
    }

    @Test func hudRerenderDuringDragKeepsTheLivePanelOrigin() {
        let dragState = FloatingPanelDragState()
        let liveOrigin = CGPoint(x: 620, y: 12)
        let staleSavedOrigin = CGPoint(x: 480, y: 190)
        var wasDraggingWhilePersisting = false

        dragState.begin()
        let renderOrigin = dragState.originForRender(
            liveOrigin: liveOrigin,
            restoredOrigin: staleSavedOrigin
        )
        dragState.finish { wasDraggingWhilePersisting = dragState.isDragging }

        #expect(renderOrigin == liveOrigin)
        #expect(wasDraggingWhilePersisting)
        #expect(!dragState.isDragging)
    }

    @Test func frontmostForeignFullscreenWindowOpensThePhysicalBottom() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let visibleFrame = CGRect(x: 0, y: 70, width: 1_440, height: 806)
        let snapshot = FloatingPanelSystemSnapshot(
            presentationOptions: [],
            frontmostPID: 200,
            ownPID: 100,
            windows: [window(pid: 200, bounds: screenFrame)]
        )

        let placementFrame = FloatingPanelPlacementPolicy.usableFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            targetDisplayBounds: screenFrame,
            snapshot: snapshot
        )

        #expect(placementFrame == CGRect(x: 0, y: 0, width: 1_440, height: 876))
    }

    @Test func fullscreenClassifierIgnoresIneligibleWindows() {
        let display = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let candidates = [
            window(pid: 200, bounds: CGRect(x: 100, y: 100, width: 900, height: 700)),
            window(pid: 201, bounds: display),
            window(pid: 200, layer: 1, bounds: display),
            window(pid: 200, alpha: 0, bounds: display)
        ]

        for candidate in candidates {
            #expect(!FloatingPanelFullscreenClassifier.covers(
                targetDisplayBounds: display,
                frontmostPID: 200,
                ownPID: 100,
                windows: [candidate]
            ))
        }
    }

    @Test func fullscreenClassifierUsesTheTargetDisplayInMultiDisplayLayouts() {
        let primary = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let secondary = CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080)
        let windows = [window(pid: 200, bounds: secondary)]

        #expect(!FloatingPanelFullscreenClassifier.covers(
            targetDisplayBounds: primary,
            frontmostPID: 200,
            ownPID: 100,
            windows: windows
        ))
        #expect(FloatingPanelFullscreenClassifier.covers(
            targetDisplayBounds: secondary,
            frontmostPID: 200,
            ownPID: 100,
            windows: windows
        ))
    }

    @Test func fullscreenClassifierAcceptsOnePointToleranceAndNinetyNinePercentCoverage() {
        let display = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let onePointInset = display.insetBy(dx: 1, dy: 1)
        let ninetyNinePercent = CGRect(x: 0, y: 0, width: 1_425.6, height: 900)

        for bounds in [onePointInset, ninetyNinePercent] {
            #expect(FloatingPanelFullscreenClassifier.covers(
                targetDisplayBounds: display,
                frontmostPID: 200,
                ownPID: 100,
                windows: [window(pid: 200, bounds: bounds)]
            ))
        }
    }

    @Test func dragCompletionCapturesOneFreshContextAndReusesThatInstance() {
        let dragState = FloatingPanelDragState()
        let dragStartContext = FloatingPanelPlacementContext(displays: [
            DisplayFrame(
                id: "main",
                visibleFrame: CGRect(x: 0, y: 70, width: 1_440, height: 806)
            )
        ])
        let completionContext = FloatingPanelPlacementContext(displays: [
            DisplayFrame(
                id: "main",
                visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 876)
            )
        ])
        var currentContext = dragStartContext
        var captureCount = 0
        var contextUsedForClamp: FloatingPanelPlacementContext?
        var contextUsedForNormalization: FloatingPanelPlacementContext?

        dragState.begin()
        currentContext = completionContext
        dragState.finish(
            capturePlacementContext: {
                captureCount += 1
                return currentContext
            },
            persist: { context in
                contextUsedForClamp = context
                contextUsedForNormalization = context
            }
        )

        #expect(captureCount == 1)
        #expect(contextUsedForClamp == completionContext)
        #expect(contextUsedForNormalization == completionContext)
        #expect(!dragState.isDragging)
    }

    @Test func fullscreenPresentationOnlyOpensTheCoveredDisplayBottom() {
        let primaryScreen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let secondaryScreen = CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080)
        let primaryVisible = CGRect(x: 0, y: 70, width: 1_440, height: 806)
        let secondaryVisible = CGRect(x: 1_440, y: 70, width: 1_920, height: 986)
        let snapshot = FloatingPanelSystemSnapshot(
            presentationOptions: [.fullScreen],
            frontmostPID: 200,
            ownPID: 100,
            windows: [window(pid: 200, bounds: primaryScreen)]
        )

        let primaryPlacement = FloatingPanelPlacementPolicy.usableFrame(
            screenFrame: primaryScreen,
            visibleFrame: primaryVisible,
            targetDisplayBounds: primaryScreen,
            snapshot: snapshot
        )
        let secondaryPlacement = FloatingPanelPlacementPolicy.usableFrame(
            screenFrame: secondaryScreen,
            visibleFrame: secondaryVisible,
            targetDisplayBounds: secondaryScreen,
            snapshot: snapshot
        )

        #expect(primaryPlacement.minY == primaryScreen.minY)
        #expect(secondaryPlacement == secondaryVisible)
    }

    private func window(
        pid: pid_t,
        layer: Int = 0,
        alpha: Double = 1,
        bounds: CGRect
    ) -> FloatingPanelWindowSnapshot {
        FloatingPanelWindowSnapshot(ownerPID: pid, layer: layer, alpha: alpha, bounds: bounds)
    }
}
