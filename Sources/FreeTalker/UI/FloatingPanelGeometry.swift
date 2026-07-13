import CoreGraphics

struct DisplayFrame: Equatable, Sendable {
    let id: String
    let visibleFrame: CGRect
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
