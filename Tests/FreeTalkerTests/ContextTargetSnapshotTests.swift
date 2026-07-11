import CoreGraphics
import Testing
@testable import FreeTalker

@MainActor
@Suite struct ContextTargetSnapshotTests {
    @Test func axWindowNumberWinsEvenWhenTitlesAreDuplicated() {
        let ax = FakeTargetAccessibility(trusted: true, metadata: .init(windowID: 22, title: "Untitled"))
        let windows = FakeWindowList(records: [
            .init(windowID: 11, processID: 41, title: "Untitled"),
            .init(windowID: 22, processID: 41, title: "Untitled")
        ])
        let snapshotter = ContextTargetSnapshotter(accessibility: ax, windows: windows)

        let snapshot = snapshotter.snapshot(appName: "Editor", bundleID: "editor", processID: 41)

        #expect(snapshot.windowID == 22)
    }

    @Test func frontToBackPIDFallbackHandlesNilTitles() {
        let ax = FakeTargetAccessibility(trusted: false, metadata: nil)
        let windows = FakeWindowList(records: [
            .init(windowID: 9, processID: 99, title: nil),
            .init(windowID: 12, processID: 41, title: nil),
            .init(windowID: 13, processID: 41, title: nil)
        ])
        let snapshotter = ContextTargetSnapshotter(accessibility: ax, windows: windows)

        let snapshot = snapshotter.snapshot(appName: "Editor", bundleID: "editor", processID: 41)

        #expect(snapshot.windowID == 12)
    }
}

@MainActor
private final class FakeTargetAccessibility: ContextTargetAccessibilityProviding {
    let trusted: Bool
    let metadata: AccessibilityWindowMetadata?
    init(trusted: Bool, metadata: AccessibilityWindowMetadata?) { self.trusted = trusted; self.metadata = metadata }
    func isTrusted() -> Bool { trusted }
    func focusedWindowMetadata(pid: pid_t) -> AccessibilityWindowMetadata? { metadata }
}

private struct FakeWindowList: ContextWindowListing {
    let records: [ContextWindowRecord]
    func frontToBackWindows() -> [ContextWindowRecord] { records }
}
