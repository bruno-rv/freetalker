import AppKit
import Foundation
import SwiftUI

/// Small floating borderless pill shown while recording/processing. See PLAN.md step 2,
/// Amendment B3 (clickable pill + mode-aware `locked` rendering).
@MainActor
final class HUDController {
    private var panel: HUDPanel?
    /// Pending auto-hide for a `flash(_:duration:)` call. Cancelled whenever `show`/`flash`/
    /// `hide` runs again (e.g. a new recording starts) so a stale timer can't hide a HUD that's
    /// since been repurposed. See Round 2 Codex finding 6.
    private var pendingHide: DispatchWorkItem?

    /// Fired when the pill is clicked (Amendment B3) — wired once by `AppCoordinator` to the
    /// recording state machine's `pillClick` event. The panel never becomes key/main (see
    /// `HUDPanel` below), so this never steals focus from the frontmost app.
    var onPillClick: (() -> Void)?

    /// What the pill currently displays. `locked`'s `previewText` is embedded INSIDE the lock
    /// glyph/elapsed layout — a live-preview tick must never replace that layout with a bare
    /// text pill. See PLAN.md Amendment B3.
    enum Mode: Equatable {
        case text(String)
        case locked(elapsed: TimeInterval, cap: TimeInterval, previewText: String?)
    }

    func show(text: String) {
        pendingHide?.cancel()
        pendingHide = nil
        display(mode: .text(text))
    }

    /// Shows a terminal notice (one the user must actually see — manual-paste, save failures)
    /// then auto-hides it after `duration`. Callers must not follow this with an unconditional
    /// `hide()`, which would otherwise clobber the message before the user reads it. See Round 2
    /// Codex finding 6.
    func flash(_ text: String, duration: TimeInterval = 2.5) {
        pendingHide?.cancel()
        display(mode: .text(text))
        let workItem = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        pendingHide = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    /// Shows the `locked`-mode layout: lock glyph + elapsed/cap time, with `previewText` (if any)
    /// embedded inside — never a bare text pill. Ticked roughly once a second by `AppCoordinator`
    /// while `locked`; live-preview ticks update only `previewText`. See PLAN.md Amendment B3.
    func showLocked(elapsed: TimeInterval, cap: TimeInterval, previewText: String?) {
        pendingHide?.cancel()
        pendingHide = nil
        display(mode: .locked(elapsed: elapsed, cap: cap, previewText: previewText))
    }

    func hide() {
        pendingHide?.cancel()
        pendingHide = nil
        panel?.orderOut(nil)
    }

    /// Tail-truncates live preview text to fit the HUD's ~2-line pill: keeps the most recent
    /// `maxCharacters` characters (what the user is currently saying, not where they started),
    /// prefixed with an ellipsis when truncated. A cheap, testable heuristic — not exact
    /// line-wrapping (the view's own `lineLimit`/truncation is the layout-level backstop). See
    /// PLAN 3 "HUD".
    nonisolated static func tailTruncate(_ text: String, maxCharacters: Int = 120) -> String {
        guard text.count > maxCharacters else { return text }
        return "…" + text.suffix(maxCharacters)
    }

    private func display(mode: Mode) {
        let hosting = NSHostingView(rootView: HUDView(mode: mode, onPillClick: { [weak self] in self?.onPillClick?() }))
        let fitting = hosting.fittingSize
        let size = NSSize(width: max(fitting.width, 60), height: max(fitting.height, 36))
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel: HUDPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = HUDPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            // Deliberately NOT true (unlike a plain notification HUD): the pill must receive
            // clicks (lock/stop gesture, B3). `HUDPanel` overrides canBecomeKey/canBecomeMain to
            // false so accepting mouse events here never steals focus from the frontmost app.
            panel.ignoresMouseEvents = false
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

/// Borderless HUD panel (Amendment B3): overrides `canBecomeKey`/`canBecomeMain` to `false` so
/// clicking the pill — needed for the lock/stop gesture — never makes this window key or main,
/// which would otherwise steal focus (and the insertion target) from the frontmost app. Combined
/// with the `.nonactivatingPanel` style mask, mouseDown is still delivered to the content view
/// on the very first click (no "wake up and focus" gate to clear first — that gate is what
/// `canBecomeKey`/`canBecomeMain` being `false` here removes).
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct HUDView: View {
    let mode: HUDController.Mode
    var onPillClick: () -> Void = {}

    var body: some View {
        content
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .onTapGesture(perform: onPillClick)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .text(let text):
            Text(text)
                .lineLimit(2)
                .truncationMode(.head)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 320, alignment: .leading)
        case .locked(let elapsed, let cap, let previewText):
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                Text(Self.formatMMSS(elapsed) + " / " + Self.formatMMSS(cap))
                    .monospacedDigit()
                if let previewText, !previewText.isEmpty {
                    Text(previewText)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
        }
    }

    private static func formatMMSS(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
