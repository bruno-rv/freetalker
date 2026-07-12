import AppKit
import Foundation
import SwiftUI

@MainActor
final class HUDController {
    private var panel: NSPanel?
    private let settings: AppSettings
    private var screenChangeObserver: NotificationObserverToken?
    /// Pending auto-hide for a `flash(_:duration:)` call. Cancelled whenever `show`/`flash`/
    /// `hide` runs again (e.g. a new recording starts) so a stale timer can't hide a HUD that's
    /// since been repurposed. See Round 2 Codex finding 6.
    private var pendingHide: DispatchWorkItem?

    var onPillClick: (() -> Void)?

    var onPanelCancel: (() -> Void)?
    var onPanelDone: (() -> Void)?
    var onPanelRaw: (() -> Void)?
    var onPanelLanguage: ((String) -> Void)?
    var onPanelOutput: ((OutputLanguage) -> Void)?
    var onPanelCycleTemplate: (() -> Void)?
    var onPanelLock: (() -> Void)?
    var onRetryTranslation: (() -> Void)?
    var onInsertSourceText: (() -> Void)?

    init(settings: AppSettings = .shared) {
        self.settings = settings
        screenChangeObserver = NotificationObserverToken(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reclampPanel() }
        })
    }

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver.value)
        }
    }

    /// What the pill currently displays.
    enum Mode: Equatable {
        case text(String)
        case recordingPanel(RecordingPanelState)
        case translationRecovery(TranslationRecoveryPresentation)
    }

    struct RecordingPanelState: Equatable {
        var isLocked: Bool
        var elapsed: TimeInterval
        var cap: TimeInterval
        var previewText: String?
        var warnings: [String]
        var activeTemplateName: String
        var localContextScopeName: String
        var localContextPermissionHint: String?
        /// nil / "en" / "pt" — which one-shot choice (if any) is currently highlighted.
        var oneShotLanguage: String?
        var translationState: TranslationControlsState
    }

    /// Bundles the Recording Panel's button callbacks for `HUDView` — closures aren't Equatable,
    /// so this stays out of `Mode`/`RecordingPanelState`.
    struct PanelCallbacks {
        var onCancel: () -> Void = {}
        var onDone: () -> Void = {}
        var onRaw: () -> Void = {}
        var onLanguage: (String) -> Void = { _ in }
        var onOutput: (OutputLanguage) -> Void = { _ in }
        var onCycleTemplate: () -> Void = {}
        var onLock: () -> Void = {}
        var onRetryTranslation: () -> Void = {}
        var onInsertSourceText: () -> Void = {}
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

    func showTranslationRecovery(_ presentation: TranslationRecoveryPresentation) {
        pendingHide?.cancel()
        pendingHide = nil
        display(mode: .translationRecovery(presentation))
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

    nonisolated static func resizedOrigin(
        preserving origin: CGPoint,
        panelSize: CGSize,
        capturedVisibleFrame: CGRect
    ) -> CGPoint {
        FloatingPanelGeometry.clampedOrigin(
            origin,
            panelSize: panelSize,
            visibleFrame: capturedVisibleFrame
        )
    }

    private func display(mode: Mode) {
        let callbacks = PanelCallbacks(
            onCancel: { [weak self] in self?.onPanelCancel?() },
            onDone: { [weak self] in self?.onPanelDone?() },
            onRaw: { [weak self] in self?.onPanelRaw?() },
            onLanguage: { [weak self] code in self?.onPanelLanguage?(code) },
            onOutput: { [weak self] language in self?.onPanelOutput?(language) },
            onCycleTemplate: { [weak self] in self?.onPanelCycleTemplate?() },
            onLock: { [weak self] in self?.onPanelLock?() },
            onRetryTranslation: { [weak self] in self?.onRetryTranslation?() },
            onInsertSourceText: { [weak self] in self?.onInsertSourceText?() }
        )
        let hosting = NSHostingView(rootView: HUDView(
            mode: mode,
            onPillClick: { [weak self] in self?.onPillClick?() },
            panelCallbacks: callbacks,
            onBackgroundDragCompleted: { [weak self] in self?.persistPanelPosition() }
        ))
        let fitting = hosting.fittingSize
        let size = NSSize(width: max(fitting.width, 60), height: max(fitting.height, 36))
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
            let origin = panel.frame.origin
            let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame
            panel.contentView = hosting
            panel.setContentSize(size)
            if let visibleFrame {
                panel.setFrameOrigin(Self.resizedOrigin(
                    preserving: origin,
                    panelSize: panel.frame.size,
                    capturedVisibleFrame: visibleFrame
                ))
            }
        } else {
            panel = Self.makePanel(size: size)
            panel.contentView = hosting
            self.panel = panel
            positionForFirstPresentation(panel)
        }

        panel.orderFrontRegardless()
    }

    static func makePanel(size: NSSize) -> NSPanel {
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The HUD must receive control taps without becoming key or moving for arbitrary clicks.
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return panel
    }

    private func positionForFirstPresentation(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let displays = NSScreen.screens.map(Self.displayFrame)
        let origin: CGPoint
        if let saved = settings.hudPosition {
            origin = FloatingPanelGeometry.restoredOrigin(
                saved: saved,
                displays: displays,
                fallback: Self.displayFrame(screen),
                panelSize: panel.frame.size
            )
        } else {
            origin = FloatingPanelGeometry.clampedOrigin(
                CGPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                        y: screen.visibleFrame.minY + 90),
                panelSize: panel.frame.size,
                visibleFrame: screen.visibleFrame
            )
        }
        panel.setFrameOrigin(origin)
    }

    private func reclampPanel() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        panel.setFrameOrigin(FloatingPanelGeometry.clampedOrigin(
            panel.frame.origin,
            panelSize: panel.frame.size,
            visibleFrame: screen.visibleFrame
        ))
    }

    private func persistPanelPosition() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        settings.hudPosition = FloatingPanelGeometry.normalizedOrigin(
            frame: panel.frame,
            display: Self.displayFrame(screen)
        )
    }

    private static func displayFrame(_ screen: NSScreen) -> DisplayFrame {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber
        return DisplayFrame(id: number?.stringValue ?? screen.localizedName,
                            visibleFrame: screen.visibleFrame)
    }
}

private final class NotificationObserverToken: @unchecked Sendable {
    let value: NSObjectProtocol

    init(_ value: NSObjectProtocol) {
        self.value = value
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
    var onBackgroundDragCompleted: () -> Void = {}

    var body: some View {
        Group {
            switch mode {
            case .text(let text):
                Text(text)
                    .lineLimit(Self.lineLimit(for: text))
                    .truncationMode(.head)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 320, alignment: .leading)
                    .onTapGesture(perform: onPillClick)
            case .recordingPanel(let state):
                VStack(alignment: .leading, spacing: 4) {
                    ViewThatFits(in: .horizontal) {
                        panelRow(state, includePreview: true)
                        panelRow(state, includePreview: false)
                    }
                    ForEach(Array(state.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                            .accessibilityLabel("Capture warning: \(warning)")
                    }
                }
                .frame(maxWidth: 460, alignment: .leading)
            case .translationRecovery(let presentation):
                VStack(alignment: .leading, spacing: 6) {
                    Text(presentation.message)
                        .foregroundStyle(.red)
                    Text(presentation.recoverableText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Button(presentation.retryTitle, action: panelCallbacks.onRetryTranslation)
                            .disabled(presentation.isRetrying)
                        Button(presentation.insertSourceTitle, action: panelCallbacks.onInsertSourceText)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(HUDDragSurface(onDragCompleted: onBackgroundDragCompleted))
        .background(.regularMaterial, in: Capsule())
    }

    nonisolated static func lineLimit(for text: String) -> Int? {
        text.contains("\n") ? nil : 2
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

            Button(
                TranslationRecoveryPresentation.sourceActionTitle(
                    outputLanguage: state.translationState.effectiveOutput
                ),
                action: panelCallbacks.onRaw
            )
                .font(.caption)
                .help("Finish without post-processing")

            TranslationControls(
                languagePin: state.oneShotLanguage ?? "auto",
                state: state.translationState,
                onLanguage: panelCallbacks.onLanguage,
                onOutput: panelCallbacks.onOutput
            )

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

private struct HUDDragSurface: NSViewRepresentable {
    let onDragCompleted: () -> Void

    func makeNSView(context: Context) -> HUDDragView {
        HUDDragView(onDragCompleted: onDragCompleted)
    }

    func updateNSView(_ view: HUDDragView, context: Context) {
        view.onDragCompleted = onDragCompleted
    }
}

private final class HUDDragView: NSView {
    var onDragCompleted: () -> Void

    init(onDragCompleted: @escaping () -> Void) {
        self.onDragCompleted = onDragCompleted
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
        onDragCompleted()
    }
}
