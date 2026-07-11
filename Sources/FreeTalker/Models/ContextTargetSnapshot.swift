import CoreGraphics
import Foundation

struct ContextTargetSnapshot: Equatable, Sendable {
    let appName: String?
    let bundleID: String?
    let processID: pid_t
    let windowID: CGWindowID?
    let windowTitle: String?
}

struct ContextWindowRecord: Equatable, Sendable {
    let windowID: CGWindowID
    let processID: pid_t
    let title: String?
}

protocol ContextWindowListing: Sendable {
    func frontToBackWindows() -> [ContextWindowRecord]
}

struct SystemContextWindowList: ContextWindowListing {
    func frontToBackWindows() -> [ContextWindowRecord] {
        guard let rows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return [] }
        return rows.compactMap { row in
            guard let number = row[kCGWindowNumber] as? NSNumber,
                  let ownerPID = row[kCGWindowOwnerPID] as? NSNumber else { return nil }
            return ContextWindowRecord(
                windowID: CGWindowID(number.uint32Value),
                processID: pid_t(ownerPID.int32Value),
                title: row[kCGWindowName] as? String
            )
        }
    }
}

@MainActor
protocol ContextTargetAccessibilityProviding: AnyObject {
    func isTrusted() -> Bool
    func focusedWindowMetadata(pid: pid_t) -> AccessibilityWindowMetadata?
}

@MainActor
struct ContextTargetSnapshotter {
    let accessibility: any ContextTargetAccessibilityProviding
    let windows: any ContextWindowListing

    init(
        accessibility: any ContextTargetAccessibilityProviding = AccessibilityContext(),
        windows: any ContextWindowListing = SystemContextWindowList()
    ) {
        self.accessibility = accessibility
        self.windows = windows
    }

    func snapshot(appName: String?, bundleID: String?, processID: pid_t) -> ContextTargetSnapshot {
        let axMetadata = accessibility.isTrusted() ? accessibility.focusedWindowMetadata(pid: processID) : nil
        let fallback = windows.frontToBackWindows().first { $0.processID == processID }
        return ContextTargetSnapshot(
            appName: appName,
            bundleID: bundleID,
            processID: processID,
            windowID: axMetadata?.windowID ?? fallback?.windowID,
            windowTitle: axMetadata?.title ?? fallback?.title
        )
    }
}
