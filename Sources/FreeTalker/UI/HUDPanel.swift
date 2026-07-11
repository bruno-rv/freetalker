import AppKit
import Foundation
import SwiftUI

@MainActor
final class HUDController {
    private var panel: HUDPanel?
    /// Pending auto-hide for a `flash(_:duration:)` call. Cancelled whenever `show`/`flash`/
    /// `hide` runs again (e.g. a new recording starts) so a stale timer can't hide a HUD that's
    /// since been repurposed. See Round 2 Codex finding 6.
    private var pendingHide: DispatchWorkItem?

    var onPillClick: (() -> Void)?

    var onPanelCancel: (() -> Void)?
    var onPanelDone: (() -> Void)?
    var onPanelRaw: (() -> Void)?
    var onPanelLanguage: ((String) -> Void)?
    var onPanelCycleTemplate: (() -> Void)?
    var onPanelLock: (() -> Void)?

    /// What the pill currently displays.
    enum Mode: Equatable {
        case text(String)
        case recordingPanel(RecordingPanelState)
    }

    struct RecordingPanelState: Equatable {
        var isLocked: Bool
        var elapsed: TimeInterval
        var cap: TimeInterval
        var previewText: String?
        var activeTemplateName: String
        var localContextScopeName: String
        var localContextPermissionHint: String?
        /// nil / "en" / "pt" — which one-shot choice (if any) is currently highlighted.
        var oneShotLanguage: String?
    }

    /// Bundles the Recording Panel's button callbacks for `HUDView` — closures aren't Equatable,
    /// so this stays out of `Mode`/`RecordingPanelState`.
    struct PanelCallbacks {
        var onCancel: () -> Void = {}
        var onDone: () -> Void = {}
        var onRaw: () -> Void = {}
        var onLanguage: (String) -> Void = { _ in }
        var onCycleTemplate: () -> Void = {}
        var onLock: () -> Void = {}
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

    func showRecordingPanel(_ state: RecordingPanelState) {
        pendingHide?.cancel()
        pendingHide = nil
        display(mode: .recordingPanel(state))
    }

    func hide() {
        pendingHide?.cancel()
        pendingHide = nil
        panel?.orderOut(nil)
    }

    nonisolated static func tailTruncate(_ text: String, maxCharacters: Int = 120) -> String {
        guard text.count > maxCharacters else { return text }
        return "…" + text.suffix(maxCharacters)
    }

    private func display(mode: Mode) {
        let callbacks = PanelCallbacks(
            onCancel: { [weak self] in self?.onPanelCancel?() },
            onDone: { [weak self] in self?.onPanelDone?() },
            onRaw: { [weak self] in self?.onPanelRaw?() },
            onLanguage: { [weak self] code in self?.onPanelLanguage?(code) },
            onCycleTemplate: { [weak self] in self?.onPanelCycleTemplate?() },
            onLock: { [weak self] in self?.onPanelLock?() }
        )
        let hosting = NSHostingView(rootView: HUDView(
            mode: mode,
            onPillClick: { [weak self] in self?.onPillClick?() },
            panelCallbacks: callbacks
        ))
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
            // Deliberately NOT true (unlike a plain notification HUD): the pill/panel must
            // receive clicks (lock/stop gesture, B3; per-control taps, Feature 3). `HUDPanel`
            // overrides canBecomeKey/canBecomeMain to false so accepting mouse events here never
            // steals focus from the frontmost app.
            panel.ignoresMouseEvents = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
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
    var panelCallbacks: HUDController.PanelCallbacks = .init()

    var body: some View {
        Group {
            switch mode {
            case .text(let text):
                Text(text)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 320, alignment: .leading)
                    .onTapGesture(perform: onPillClick)
            case .recordingPanel(let state):
                ViewThatFits(in: .horizontal) {
                    panelRow(state, includePreview: true)
                    panelRow(state, includePreview: false)
                }
                .frame(maxWidth: 460, alignment: .leading)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
    }

    @ViewBuilder
    private func panelRow(_ state: HUDController.RecordingPanelState, includePreview: Bool) -> some View {
        HStack(spacing: 8) {
            if state.isLocked {
                Image(systemName: "lock.fill")
                Text(Self.formatMMSS(state.elapsed) + " / " + Self.formatMMSS(state.cap))
                    .monospacedDigit()
                    .font(.caption)
            }
            if includePreview, let previewText = state.previewText, !previewText.isEmpty {
                Text(previewText)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Text("Context: \(state.localContextScopeName)")
                .font(.caption2)
                .foregroundStyle(state.localContextPermissionHint == nil ? Color.secondary : Color.orange)
                .help(state.localContextPermissionHint ?? "Local context scope")
                .accessibilityLabel("Local context: \(state.localContextScopeName)")
                .accessibilityHint(state.localContextPermissionHint ?? "Captured once when recording stops")

            Button(action: panelCallbacks.onCancel) {
                Image(systemName: "xmark.circle")
            }
            .help("Cancel")

            Button(action: panelCallbacks.onDone) {
                Image(systemName: "checkmark.circle")
            }
            .help("Done")

            Button("Raw", action: panelCallbacks.onRaw)
                .font(.caption)
                .help("Finish without post-processing")

            Button("EN") { panelCallbacks.onLanguage("en") }
                .font(.caption)
                .foregroundStyle(state.oneShotLanguage == "en" ? Color.accentColor : Color.primary)
            Button("PT") { panelCallbacks.onLanguage("pt") }
                .font(.caption)
                .foregroundStyle(state.oneShotLanguage == "pt" ? Color.accentColor : Color.primary)

            Button(action: panelCallbacks.onCycleTemplate) {
                Text(state.activeTemplateName)
                    .lineLimit(1)
                    .frame(maxWidth: 120, alignment: .leading)
            }

            if !state.isLocked {
                Button(action: panelCallbacks.onLock) {
                    Image(systemName: "lock")
                }
                .help("Lock (hands-free)")
            }
        }
        .buttonStyle(.plain)
    }

    private static func formatMMSS(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
