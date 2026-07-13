import AppKit

struct DisplayFrame: Equatable, Sendable {
    let id: String
    let visibleFrame: CGRect
}

struct FloatingPanelWindowSnapshot: Equatable, Sendable {
    let ownerPID: pid_t
    let layer: Int
    let alpha: Double
    let bounds: CGRect
}

struct FloatingPanelSystemSnapshot: Equatable, Sendable {
    let presentationOptions: NSApplication.PresentationOptions
    let frontmostPID: pid_t?
    let ownPID: pid_t
    let windows: [FloatingPanelWindowSnapshot]

    @MainActor
    static func capture() -> Self {
        let windowDictionaries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let windows = windowDictionaries.compactMap { dictionary -> FloatingPanelWindowSnapshot? in
            guard
                let ownerPID = (dictionary[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                let layer = (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue,
                let alpha = (dictionary[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else { return nil }
            return FloatingPanelWindowSnapshot(
                ownerPID: ownerPID,
                layer: layer,
                alpha: alpha,
                bounds: bounds
            )
        }
        return Self(
            presentationOptions: NSApp.currentSystemPresentationOptions,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            windows: windows
        )
    }
}

struct FloatingPanelPlacementContext: Equatable, Sendable {
    let displays: [DisplayFrame]

    func display(id: String) -> DisplayFrame? {
        displays.first { $0.id == id }
    }
}

enum FloatingPanelFullscreenClassifier {
    static func covers(
        targetDisplayBounds: CGRect,
        frontmostPID: pid_t?,
        ownPID: pid_t,
        windows: [FloatingPanelWindowSnapshot]
    ) -> Bool {
        guard
            let frontmostPID,
            frontmostPID != ownPID,
            targetDisplayBounds.width > 0,
            targetDisplayBounds.height > 0
        else { return false }

        let targetArea = targetDisplayBounds.width * targetDisplayBounds.height
        return windows.contains { window in
            guard
                window.ownerPID == frontmostPID,
                window.layer == 0,
                window.alpha > 0
            else { return false }

            let intersection = window.bounds.intersection(targetDisplayBounds)
            let coverage = intersection.isNull
                ? 0
                : (intersection.width * intersection.height) / targetArea
            let tolerance: CGFloat = 1
            let matchesWithinTolerance =
                abs(window.bounds.minX - targetDisplayBounds.minX) <= tolerance
                && abs(window.bounds.minY - targetDisplayBounds.minY) <= tolerance
                && abs(window.bounds.maxX - targetDisplayBounds.maxX) <= tolerance
                && abs(window.bounds.maxY - targetDisplayBounds.maxY) <= tolerance
            return matchesWithinTolerance || coverage >= 0.99
        }
    }
}

enum FloatingPanelPlacementPolicy {
    static func usableFrame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        presentationOptions: NSApplication.PresentationOptions
    ) -> CGRect {
        usableFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            targetDisplayBounds: screenFrame,
            snapshot: FloatingPanelSystemSnapshot(
                presentationOptions: presentationOptions,
                frontmostPID: nil,
                ownPID: 0,
                windows: []
            )
        )
    }

    static func usableFrame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        targetDisplayBounds: CGRect,
        snapshot: FloatingPanelSystemSnapshot
    ) -> CGRect {
        let nativePresentationHidesDock = !snapshot.presentationOptions.intersection([
            .autoHideDock, .hideDock
        ]).isEmpty
        let foreignFullscreenCoversDisplay = !nativePresentationHidesDock
            && FloatingPanelFullscreenClassifier.covers(
                targetDisplayBounds: targetDisplayBounds,
                frontmostPID: snapshot.frontmostPID,
                ownPID: snapshot.ownPID,
                windows: snapshot.windows
            )
        guard nativePresentationHidesDock || foreignFullscreenCoversDisplay else {
            return visibleFrame
        }

        let upperEdge = min(screenFrame.maxY, visibleFrame.maxY)
        return CGRect(
            x: visibleFrame.minX,
            y: screenFrame.minY,
            width: visibleFrame.width,
            height: max(0, upperEdge - screenFrame.minY)
        )
    }

    @MainActor
    static func captureContext() -> FloatingPanelPlacementContext {
        captureContext(screens: NSScreen.screens, snapshot: .capture())
    }

    @MainActor
    static func captureContext(
        screens: [NSScreen],
        snapshot: FloatingPanelSystemSnapshot
    ) -> FloatingPanelPlacementContext {
        FloatingPanelPlacementContext(displays: screens.map { screen in
            let displayNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
            let targetDisplayBounds = displayNumber.map {
                CGDisplayBounds(CGDirectDisplayID($0.uint32Value))
            } ?? screen.frame
            return DisplayFrame(
                id: displayID(for: screen),
                visibleFrame: usableFrame(
                    screenFrame: screen.frame,
                    visibleFrame: screen.visibleFrame,
                    targetDisplayBounds: targetDisplayBounds,
                    snapshot: snapshot
                )
            )
        })
    }

    @MainActor
    static func displayID(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber
        return number?.stringValue ?? screen.localizedName
    }
}

final class FloatingPanelDragState {
    private(set) var isDragging = false

    func begin() {
        isDragging = true
    }

    func originForRender(liveOrigin: CGPoint, restoredOrigin: CGPoint) -> CGPoint {
        isDragging ? liveOrigin : restoredOrigin
    }

    func finish(persist: () -> Void) {
        guard isDragging else { return }
        persist()
        isDragging = false
    }

    func finish(
        capturePlacementContext: () -> FloatingPanelPlacementContext,
        persist: (FloatingPanelPlacementContext) -> Void
    ) {
        guard isDragging else { return }
        let placementContext = capturePlacementContext()
        persist(placementContext)
        isDragging = false
    }
}

enum FloatingPanelGeometry {
    static func launcherFrame(
        edge: LauncherEdge,
        position: Double,
        panelSize: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        let position = clampedUnit(position)
        let horizontalTravel = max(0, visibleFrame.width - panelSize.width)
        let verticalTravel = max(0, visibleFrame.height - panelSize.height)
        let origin: CGPoint

        switch edge {
        case .left:
            origin = CGPoint(
                x: visibleFrame.minX,
                y: visibleFrame.minY + verticalTravel * position
            )
        case .right:
            origin = CGPoint(
                x: visibleFrame.maxX - panelSize.width,
                y: visibleFrame.minY + verticalTravel * position
            )
        case .top:
            origin = CGPoint(
                x: visibleFrame.minX + horizontalTravel * position,
                y: visibleFrame.maxY - panelSize.height
            )
        case .bottom:
            origin = CGPoint(
                x: visibleFrame.minX + horizontalTravel * position,
                y: visibleFrame.minY
            )
        }

        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - panelSize.height)
        return CGRect(
            origin: CGPoint(
                x: min(max(origin.x, visibleFrame.minX), maximumX),
                y: min(max(origin.y, visibleFrame.minY), maximumY)
            ),
            size: panelSize
        )
    }

    static func normalizedOrigin(
        frame: CGRect,
        display: DisplayFrame
    ) -> NormalizedWindowPosition {
        let horizontalTravel = display.visibleFrame.width - frame.width
        let verticalTravel = display.visibleFrame.height - frame.height
        return NormalizedWindowPosition(
            displayID: display.id,
            x: normalizedCoordinate(
                frame.minX - display.visibleFrame.minX,
                travel: horizontalTravel
            ),
            y: normalizedCoordinate(
                frame.minY - display.visibleFrame.minY,
                travel: verticalTravel
            )
        )
    }

    static func legacyLauncherPosition(
        edge: LauncherEdge,
        position: Double,
        panelSize: CGSize,
        display: DisplayFrame
    ) -> NormalizedWindowPosition {
        normalizedOrigin(
            frame: launcherFrame(
                edge: edge,
                position: position,
                panelSize: panelSize,
                visibleFrame: display.visibleFrame
            ),
            display: display
        )
    }

    static func restoredOrigin(
        saved: NormalizedWindowPosition?,
        displays: [DisplayFrame],
        fallback: DisplayFrame,
        panelSize: CGSize
    ) -> CGPoint {
        guard let saved else {
            return clampedOrigin(
                fallback.visibleFrame.origin,
                panelSize: panelSize,
                visibleFrame: fallback.visibleFrame
            )
        }

        let display = displays.first { $0.id == saved.displayID } ?? fallback
        let origin = CGPoint(
            x: display.visibleFrame.minX
                + max(0, display.visibleFrame.width - panelSize.width) * clampedUnit(saved.x),
            y: display.visibleFrame.minY
                + max(0, display.visibleFrame.height - panelSize.height) * clampedUnit(saved.y)
        )
        return clampedOrigin(origin, panelSize: panelSize, visibleFrame: display.visibleFrame)
    }

    static func clampedOrigin(
        _ origin: CGPoint,
        panelSize: CGSize,
        visibleFrame: CGRect,
        minimumVisible: CGSize = CGSize(width: 48, height: 32)
    ) -> CGPoint {
        let horizontalBounds: (minimum: CGFloat, maximum: CGFloat)
        if panelSize.width <= visibleFrame.width {
            horizontalBounds = (visibleFrame.minX, visibleFrame.maxX - panelSize.width)
        } else {
            let visibleWidth = min(panelSize.width, minimumVisible.width)
            horizontalBounds = (
                visibleFrame.minX - panelSize.width + visibleWidth,
                visibleFrame.maxX - visibleWidth
            )
        }
        let verticalBounds: (minimum: CGFloat, maximum: CGFloat)
        if panelSize.height <= visibleFrame.height {
            verticalBounds = (visibleFrame.minY, visibleFrame.maxY - panelSize.height)
        } else {
            let visibleHeight = min(panelSize.height, minimumVisible.height)
            verticalBounds = (
                visibleFrame.minY - panelSize.height + visibleHeight,
                visibleFrame.maxY - visibleHeight
            )
        }

        return CGPoint(
            x: min(max(origin.x, horizontalBounds.minimum), horizontalBounds.maximum),
            y: min(max(origin.y, verticalBounds.minimum), verticalBounds.maximum)
        )
    }

    private static func normalizedCoordinate(_ offset: CGFloat, travel: CGFloat) -> Double {
        guard travel > 0 else { return 0.5 }
        return clampedUnit(offset / travel)
    }

    private static func clampedUnit<T: BinaryFloatingPoint>(_ value: T) -> T {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }
}
