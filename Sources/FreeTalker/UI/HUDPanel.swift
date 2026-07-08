import AppKit
import SwiftUI

/// Small floating borderless pill shown while recording/processing. See PLAN.md step 2.
@MainActor
final class HUDController {
    private var panel: NSPanel?
    /// Pending auto-hide for a `flash(_:duration:)` call. Cancelled whenever `show`/`flash`/
    /// `hide` runs again (e.g. a new recording starts) so a stale timer can't hide a HUD that's
    /// since been repurposed. See Round 2 Codex finding 6.
    private var pendingHide: DispatchWorkItem?

    func show(text: String) {
        pendingHide?.cancel()
        pendingHide = nil
        display(text: text)
    }

    /// Shows a terminal notice (one the user must actually see — manual-paste, save failures)
    /// then auto-hides it after `duration`. Callers must not follow this with an unconditional
    /// `hide()`, which would otherwise clobber the message before the user reads it. See Round 2
    /// Codex finding 6.
    func flash(_ text: String, duration: TimeInterval = 2.5) {
        pendingHide?.cancel()
        display(text: text)
        let workItem = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        pendingHide = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    func hide() {
        pendingHide?.cancel()
        pendingHide = nil
        panel?.orderOut(nil)
    }

    private func display(text: String) {
        let hosting = NSHostingView(rootView: HUDView(text: text))
        let fitting = hosting.fittingSize
        let size = NSSize(width: max(fitting.width, 60), height: max(fitting.height, 36))
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
            self.panel = panel
        }

        panel.contentView = hosting
        panel.setContentSize(size)
        position(panel)
        panel.orderFrontRegardless()
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.midX - panel.frame.width / 2
        let y = frame.minY + 90
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

struct HUDView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
    }
}
