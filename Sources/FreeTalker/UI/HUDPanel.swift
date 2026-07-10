import AppKit
import Foundation
import SwiftUI

/// Small floating borderless pill shown while recording/processing. See PLAN.md step 2,
/// Amendment B3 (clickable pill), and PLAN.md step 9 (Recording Panel: a button row while
/// actually recording).
@MainActor
final class HUDController {
    private var panel: HUDPanel?
    /// Pending auto-hide for a `flash(_:duration:)` call. Cancelled whenever `show`/`flash`/
    /// `hide` runs again (e.g. a new recording starts) so a stale timer can't hide a HUD that's
    /// since been repurposed. See Round 2 Codex finding 6.
    private var pendingHide: DispatchWorkItem?

    /// Fired when the pill is clicked (Amendment B3) — wired once by `AppCoordinator` to the
    /// recording state machine's `pillClick` event. The panel never becomes key/main (see
    /// `HUDPanel` below), so this never steals focus from the frontmost app. Only meaningful in
    /// `.text` mode — `.recordingPanel` mode has no whole-capsule tap target (each control is its
    /// own), see PLAN.md step 9.
    var onPillClick: (() -> Void)?

    /// Recording Panel button callbacks (Feature 3) — each control's own explicit tap target,
    /// wired once by `AppCoordinator`. See PLAN.md step 9/10.
    var onPanelCancel: (() -> Void)?
    var onPanelDone: (() -> Void)?
    var onPanelRaw: (() -> Void)?
    var onPanelLanguage: ((String) -> Void)?
    var onPanelCycleTemplate: (() -> Void)?
    var onPanelLock: (() -> Void)?

    /// What the pill currently displays.
    enum Mode: Equatable {
        case text(String)
        /// Both recording states (pttRecording + locked) — a button row inside the same
        /// floating panel. See PLAN.md step 9.
        case recordingPanel(RecordingPanelState)
    }

    /// Everything the Recording Panel's view needs to render one frame — a plain value so
    /// `AppCoordinator` can rebuild it fresh from its own state on every update (capture start,
    /// live-preview tick, locked-mode timer tick, one-shot/template change). See PLAN.md step 9.
    struct RecordingPanelState: Equatable {
        /// `true` only while `locked` — gates the elapsed/cap readout and hides the Lock button
        /// (already locked). See PLAN.md step 9.
        var isLocked: Bool
        var elapsed: TimeInterval
        var cap: TimeInterval
        var previewText: String?
        var activeTemplateName: String
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

    /// Shows the Recording Panel's button-row layout (Feature 3) for the given state — ticked
    /// roughly once a second while `locked`, and on capture start / live-preview ticks /
    /// one-shot-language / template-cycle changes. See PLAN.md step 9.
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
                // Layout contract (PLAN.md step 9): fixed maxWidth 460; the whole-capsule tap
                // gesture is REMOVED in this mode — each control below is its own explicit tap
                // target, so no parent gesture exists to double-fire or swallow a child tap.
                // `ViewThatFits` drops the preview text first when the row doesn't fit; every
                // other control is fixed-size and never dropped.
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
