import AppKit
import CoreGraphics

/// Validated geometry for a built-in notched display.
/// Interactive content must sit at or below `contentMaxY`.
struct NotchGeometry: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let safeAreaTop: CGFloat
    /// Gap between `auxiliaryTopLeft` and `auxiliaryTopRight`, in screen coordinates.
    let notchFrame: CGRect

    /// Bottom edge of the menu-bar / notch safe-area strip.
    var contentMaxY: CGFloat {
        screenFrame.maxY - safeAreaTop
    }

    /// Origin Y so a panel of `panelHeight` sits flush under the safe-area strip.
    func contentOriginY(panelHeight: CGFloat) -> CGFloat {
        contentMaxY - panelHeight
    }

    /// Noninteractive connector strip under the camera housing (notch-width, safe-area height).
    var connectorFrame: CGRect {
        CGRect(
            x: notchFrame.minX,
            y: contentMaxY,
            width: notchFrame.width,
            height: safeAreaTop
        )
    }
}

/// Snapshot inputs for pure notch resolution (no live AppKit calls).
struct NotchScreenDescriptor: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let isBuiltin: Bool
    let safeAreaTop: CGFloat
    let auxiliaryTopLeft: CGRect?
    let auxiliaryTopRight: CGRect?
}

enum NotchRejectionReason: String, Error, Equatable, Sendable {
    case notBuiltin
    case noSafeAreaTop
    case missingAuxiliaryAreas
    case invalidNotchGap
}

enum NotchGeometryResolver {
    /// First screen that fully validates as a built-in notched display, or `nil`.
    /// Never falls back to width guesses or `screens.first` without validation.
    static func resolve(screens: [NotchScreenDescriptor]) -> NotchGeometry? {
        for screen in screens {
            if case .success(let geometry) = evaluate(screen) {
                return geometry
            }
        }
        return nil
    }

    static func evaluate(
        _ screen: NotchScreenDescriptor
    ) -> Result<NotchGeometry, NotchRejectionReason> {
        guard screen.isBuiltin else {
            return Result.failure(NotchRejectionReason.notBuiltin)
        }
        guard screen.safeAreaTop > 0, screen.safeAreaTop.isFinite else {
            return Result.failure(NotchRejectionReason.noSafeAreaTop)
        }
        guard let left = screen.auxiliaryTopLeft, let right = screen.auxiliaryTopRight else {
            return Result.failure(NotchRejectionReason.missingAuxiliaryAreas)
        }
        guard
            isValidAuxiliary(left, in: screen.frame),
            isValidAuxiliary(right, in: screen.frame)
        else {
            return Result.failure(NotchRejectionReason.invalidNotchGap)
        }

        // Ordered gap strictly between the two auxiliary areas.
        let gapMinX = left.maxX
        let gapMaxX = right.minX
        guard gapMinX < gapMaxX else {
            return Result.failure(NotchRejectionReason.invalidNotchGap)
        }

        let gapMinY = max(left.minY, right.minY)
        let gapMaxY = min(left.maxY, right.maxY)
        guard gapMinY < gapMaxY else {
            return Result.failure(NotchRejectionReason.invalidNotchGap)
        }

        let notchFrame = CGRect(
            x: gapMinX,
            y: gapMinY,
            width: gapMaxX - gapMinX,
            height: gapMaxY - gapMinY
        )
        guard
            isFiniteRect(notchFrame),
            !notchFrame.isEmpty,
            screen.frame.contains(notchFrame)
        else {
            return Result.failure(NotchRejectionReason.invalidNotchGap)
        }

        return Result.success(
            NotchGeometry(
                displayID: screen.displayID,
                screenFrame: screen.frame,
                safeAreaTop: screen.safeAreaTop,
                notchFrame: notchFrame
            )
        )
    }

    private static func isValidAuxiliary(_ rect: CGRect, in frame: CGRect) -> Bool {
        guard isFiniteRect(rect), !rect.isNull, !rect.isInfinite, !rect.isEmpty else {
            return false
        }
        // Contained in the screen and top-aligned with its upper edge.
        guard frame.contains(rect), rect.maxY == frame.maxY else { return false }
        return true
    }

    private static func isFiniteRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.size.width.isFinite
            && rect.size.height.isFinite
    }
}

// MARK: - AppKit bridge

enum NotchScreenSnapshot {
    /// Captures pure descriptors from live screens for the resolver.
    @MainActor
    static func descriptors(from screens: [NSScreen] = NSScreen.screens) -> [NotchScreenDescriptor] {
        screens.compactMap(descriptor(from:))
    }

    @MainActor
    static func descriptor(from screen: NSScreen) -> NotchScreenDescriptor? {
        guard let displayID = displayID(for: screen) else { return nil }
        return NotchScreenDescriptor(
            displayID: displayID,
            frame: screen.frame,
            isBuiltin: CGDisplayIsBuiltin(displayID) != 0,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeft: usableAuxiliary(screen.auxiliaryTopLeftArea),
            auxiliaryTopRight: usableAuxiliary(screen.auxiliaryTopRightArea)
        )
    }

    @MainActor
    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number.map { CGDirectDisplayID($0.uint32Value) }
    }

    private static func usableAuxiliary(_ rect: CGRect?) -> CGRect? {
        guard let rect, !rect.isNull, !rect.isInfinite else { return nil }
        return rect
    }
}
