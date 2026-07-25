import AppKit
import SwiftUI

/// Plain mutable box so the SwiftUI content's `onFinish` closure can be wired to
/// `[weak self]` after `self` exists — `NSHostingView`'s `rootView` has to be built before
/// `super.init(window:)` runs, so it can't capture `self` directly at construction time.
@MainActor
private final class FinishBox {
    var action: () -> Void = {}
}

/// Owns the one-time first-run walkthrough window (`BRAINSTORM_INSTALL_AND_UPDATES.md`
/// decision 4), opened from `FreeTalkerApp.init()` when `AppSettings.hasCompletedFirstRunWalkthrough`
/// is still `false`. Marks it completed both on "Get Started" and on the window simply being
/// closed — either way it has done its job and shouldn't reappear; permission status remains
/// visible afterward in Settings → Privacy.
@MainActor
final class FirstRunWalkthroughWindowController: NSWindowController, NSWindowDelegate {
    static let shared = FirstRunWalkthroughWindowController()

    private let finishBox = FinishBox()

    private init() {
        let box = finishBox
        let hosting = NSHostingView(rootView: FirstRunWalkthroughView(onFinish: { box.action() }))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        finishBox.action = { [weak self] in self?.finish() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func open() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        AppSettings.shared.hasCompletedFirstRunWalkthrough = true
    }

    private func finish() {
        AppSettings.shared.hasCompletedFirstRunWalkthrough = true
        close()
    }
}
