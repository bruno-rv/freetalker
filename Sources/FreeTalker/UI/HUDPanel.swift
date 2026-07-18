import AppKit
import Combine
import Foundation
import OSLog
import SwiftUI

// MARK: - Pure presentation helpers (headless-testable)

/// Routing + lifetime decisions extracted from `HUDController` for unit tests.
enum NotchpadPresentationLogic {
    enum SurfaceStyle: Equatable, Sendable {
        case floating
        case notch
    }

    enum PresentationLifetime: Equatable, Sendable {
        case persistentBase
        case terminalFlash
        case restoreBaseFlash
    }

    enum FlashLifetime: Equatable, Sendable {
        case terminal
        case restoreBase

        var presentation: PresentationLifetime {
            switch self {
            case .terminal: return .terminalFlash
            case .restoreBase: return .restoreBaseFlash
            }
        }
    }

    enum ExpiryKind: Equatable, Sendable {
        case terminal
        case restoreBase
    }

    /// Result of applying a public entry point against retained base/overlay state.
    enum PresentAction: Equatable {
        /// Same-recording panel tick under an active restore-base overlay — store base, keep overlay.
        case updateBaseUnderOverlay
        /// Replace base; cancel overlay/timer when `cancelOverlay` is true.
        case setBase(cancelOverlay: Bool)
        /// Terminal flash: clear base, show flash as the sole presentation, auto-hide.
        case terminalFlash
        /// Restore-base flash: keep base, show flash as overlay, restore base on expiry.
        case restoreBaseFlash
    }

    enum ExpiryAction: Equatable, Sendable {
        case noOp
        case restoreBase
        case hideAll
    }

    struct RoutingSnapshot: Equatable, Sendable {
        let surfaceStyle: SurfaceStyle
        let geometry: NotchGeometry?
        let displayID: CGDirectDisplayID?
        let isBuiltin: Bool?
        let rejection: String?
    }

    static func route(enabled: Bool, geometry: NotchGeometry?) -> SurfaceStyle {
        (enabled && geometry != nil) ? .notch : .floating
    }

    static func route(enabled: Bool, hasValidGeometry: Bool) -> SurfaceStyle {
        (enabled && hasValidGeometry) ? .notch : .floating
    }

    /// Captures the actual display selected (or rejected) by the resolver. Candidates are
    /// considered in display-ID order, with valid built-ins preferred over invalid/external
    /// descriptors, so observability does not depend on `screens.first`.
    static func routingSnapshot(
        enabled: Bool,
        descriptors: [NotchScreenDescriptor]
    ) -> RoutingSnapshot {
        guard enabled else {
            return RoutingSnapshot(
                surfaceStyle: .floating,
                geometry: nil,
                displayID: nil,
                isBuiltin: nil,
                rejection: "disabled"
            )
        }

        let ordered = descriptors.sorted { lhs, rhs in
            if lhs.displayID != rhs.displayID { return lhs.displayID < rhs.displayID }
            return lhs.frame.origin.x < rhs.frame.origin.x
        }
        let valid = ordered.compactMap { descriptor -> NotchGeometry? in
            guard case .success(let geometry) = NotchGeometryResolver.evaluate(descriptor) else {
                return nil
            }
            return geometry
        }
        if let geometry = valid.first {
            return RoutingSnapshot(
                surfaceStyle: .notch,
                geometry: geometry,
                displayID: geometry.displayID,
                isBuiltin: true,
                rejection: nil
            )
        }

        let candidate = ordered.first(where: { $0.isBuiltin }) ?? ordered.first
        let rejection: String
        if let candidate,
           case .failure(let reason) = NotchGeometryResolver.evaluate(candidate) {
            rejection = reason.rawValue
        } else if ordered.isEmpty {
            rejection = "noScreens"
        } else {
            rejection = "noValidNotch"
        }
        return RoutingSnapshot(
            surfaceStyle: .floating,
            geometry: nil,
            displayID: candidate?.displayID,
            isBuiltin: candidate?.isBuiltin,
            rejection: rejection
        )
    }

    static func connectorShouldBeVisible(
        controllerVisible: Bool,
        surfaceStyle: SurfaceStyle
    ) -> Bool {
        controllerVisible && surfaceStyle == .notch
    }

    /// Classifies whether an incoming `showRecordingPanel` may update the base under a restore-base overlay.
    static func isSameRecordingBaseUpdate(
        incoming: HUDController.Mode,
        currentBase: HUDController.Mode?
    ) -> Bool {
        guard case let .recordingPanel(incomingState) = incoming,
              case let .recordingPanel(currentState) = currentBase else {
            return false
        }
        return incomingState.recordingGeneration == currentState.recordingGeneration
    }

    static func presentAction(
        mode: HUDController.Mode,
        lifetime: PresentationLifetime,
        currentBase: HUDController.Mode?,
        hasRestoreBaseOverlay: Bool
    ) -> PresentAction {
        switch lifetime {
        case .persistentBase:
            if hasRestoreBaseOverlay,
               isSameRecordingBaseUpdate(incoming: mode, currentBase: currentBase) {
                return .updateBaseUnderOverlay
            }
            return .setBase(cancelOverlay: true)
        case .terminalFlash:
            return .terminalFlash
        case .restoreBaseFlash:
            return .restoreBaseFlash
        }
    }

    static func expiryAction(
        scheduledGeneration: UInt,
        eventGeneration: UInt,
        kind: ExpiryKind
    ) -> ExpiryAction {
        guard eventGeneration == scheduledGeneration else { return .noOp }
        switch kind {
        case .restoreBase: return .restoreBase
        case .terminal: return .hideAll
        }
    }

    /// Displayed mode is overlay when present, otherwise base.
    static func displayedMode(
        base: HUDController.Mode?,
        overlay: HUDController.Mode?
    ) -> HUDController.Mode? {
        overlay ?? base
    }
}

// MARK: - HUDController

@MainActor
final class HUDController {
    typealias SurfaceStyle = NotchpadPresentationLogic.SurfaceStyle
    typealias PresentationLifetime = NotchpadPresentationLogic.PresentationLifetime
    typealias FlashLifetime = NotchpadPresentationLogic.FlashLifetime

    private var panel: NSPanel?
    private var connectorPanel: NSPanel?
    private let settings: AppSettings
    private let panelDragState = FloatingPanelDragState()
    private var screenChangeObserver: NotificationObserverToken?
    private var activeSpaceObserver: NotificationObserverToken?
    private var cancellables = Set<AnyCancellable>()

    /// Retained base presentation (recording panel, persistent text, translation recovery).
    private var baseMode: Mode?
    /// Transient overlay (restore-base flash only). Terminal flashes replace `baseMode`.
    private var overlayMode: Mode?
    private var pendingHide: DispatchWorkItem?
    private var timerGeneration: UInt = 0
    private var pendingExpiryKind: NotchpadPresentationLogic.ExpiryKind?
    private var controllerVisible = false
    private var surfaceStyle: SurfaceStyle = .floating
    private var lastResolvedGeometry: NotchGeometry?
    private var lastLoggedSurface: SurfaceStyle?
    private var lastLoggedDisplayID: CGDirectDisplayID?
    private var lastLoggedBuiltin: Bool?
    private var lastLoggedRejection: String?

    private static let logger = Logger(subsystem: "org.freetalker.app", category: "notchpad")

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
            Task { @MainActor in self?.handleRoutingEnvironmentChange() }
        })
        activeSpaceObserver = NotificationObserverToken(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleRoutingEnvironmentChange() }
            }
        )
        settings.$notchpadEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleRoutingEnvironmentChange()
            }
            .store(in: &cancellables)
    }

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver.value)
        }
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver.value)
        }
    }

    /// What the pill currently displays.
    enum Mode: Equatable {
        case text(String)
        case recordingPanel(RecordingPanelState)
        case translationRecovery(TranslationRecoveryPresentation)
    }

    struct RecordingPanelState: Equatable {
        /// Identity of the recording that owns this state. A new recording must not update a
        /// prior recording's base while a restore-base warning overlay is visible.
        var recordingGeneration: Int = 0
        var isLocked: Bool
        var elapsed: TimeInterval
        var cap: TimeInterval
        var previewText: String?
        var warnings: [String]
        var activeTemplateName: String
        var localContextScopeName: String
        var localContextPermissionHint: String?
        /// nil, or a code from `languageOptions` — which one-shot choice (if any) is currently
        /// highlighted.
        var oneShotLanguage: String?
        /// The Dictation Language Set snapshotted at Recording start (F5.5) — feeds this panel's
        /// `TranslationControls` spoken-language menu. See `AppCoordinator.recordingLanguageSnapshot`.
        var languageOptions: [String] = []
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

    /// Headless lifecycle snapshot used by tests and diagnostics; no AppKit view inspection is
    /// required to verify overlay/base ownership or atomic hide transitions.
    struct PresentationSnapshot: Equatable {
        let baseMode: Mode?
        let overlayMode: Mode?
        let controllerVisible: Bool
        let pendingExpiryKind: NotchpadPresentationLogic.ExpiryKind?
        let timerGeneration: UInt
        let surfaceStyle: SurfaceStyle
        let connectorVisible: Bool
    }

    /// Floating position key surface — orthogonal to `SurfaceStyle` (notch vs floating chrome).
    private enum PositionSurface {
        case recording
        case transient
    }

    // MARK: Public API

    var presentationSnapshot: PresentationSnapshot {
        PresentationSnapshot(
            baseMode: baseMode,
            overlayMode: overlayMode,
            controllerVisible: controllerVisible,
            pendingExpiryKind: pendingExpiryKind,
            timerGeneration: timerGeneration,
            surfaceStyle: surfaceStyle,
            connectorVisible: NotchpadPresentationLogic.connectorShouldBeVisible(
                controllerVisible: controllerVisible,
                surfaceStyle: surfaceStyle
            )
        )
    }

    func show(text: String) {
        present(mode: .text(text), lifetime: .persistentBase)
    }

    /// Terminal notice by default (clears base, auto-hides). Pass `lifetime: .restoreBase` for
    /// mid-recording warnings that must restore the recording panel when the timer fires.
    func flash(
        _ text: String,
        duration: TimeInterval = 2.5,
        lifetime: FlashLifetime = .terminal
    ) {
        present(
            mode: .text(text),
            lifetime: lifetime.presentation,
            flashDuration: duration
        )
    }

    func showRecordingPanel(_ state: RecordingPanelState) {
        present(mode: .recordingPanel(state), lifetime: .persistentBase)
    }

    func showTranslationRecovery(_ presentation: TranslationRecoveryPresentation) {
        present(mode: .translationRecovery(presentation), lifetime: .persistentBase)
    }

    /// Atomic hide: clears base, overlay, timer generation, connector, and marks invisible.
    func hide() {
        cancelOverlayTimer()
        baseMode = nil
        overlayMode = nil
        controllerVisible = false
        panel?.orderOut(nil)
        updateConnector()
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

    // MARK: Presentation core

    private func present(
        mode: Mode,
        lifetime: PresentationLifetime,
        flashDuration: TimeInterval = 2.5
    ) {
        let hasRestoreOverlay = overlayMode != nil && pendingExpiryKind == .restoreBase
        let action = NotchpadPresentationLogic.presentAction(
            mode: mode,
            lifetime: lifetime,
            currentBase: baseMode,
            hasRestoreBaseOverlay: hasRestoreOverlay
        )

        switch action {
        case .updateBaseUnderOverlay:
            baseMode = mode
            // Visible content remains the overlay; base is retained for restore.
            return
        case .setBase(let cancelOverlay):
            if cancelOverlay {
                cancelOverlayTimer()
                overlayMode = nil
            }
            baseMode = mode
            controllerVisible = true
            renderActivePresentation()
        case .terminalFlash:
            cancelOverlayTimer()
            overlayMode = nil
            baseMode = mode
            controllerVisible = true
            renderActivePresentation()
            scheduleExpiry(kind: .terminal, duration: flashDuration)
        case .restoreBaseFlash:
            // Keep base; replace overlay and its timer generation.
            cancelOverlayTimer()
            overlayMode = mode
            controllerVisible = true
            renderActivePresentation()
            scheduleExpiry(kind: .restoreBase, duration: flashDuration)
        }
    }

    private func scheduleExpiry(kind: NotchpadPresentationLogic.ExpiryKind, duration: TimeInterval) {
        timerGeneration &+= 1
        let generation = timerGeneration
        pendingExpiryKind = kind
        let workItem = DispatchWorkItem { [weak self] in
            self?.expire(generation: generation, kind: kind)
        }
        pendingHide = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    private func expire(generation: UInt, kind: NotchpadPresentationLogic.ExpiryKind) {
        let action = NotchpadPresentationLogic.expiryAction(
            scheduledGeneration: timerGeneration,
            eventGeneration: generation,
            kind: kind
        )
        switch action {
        case .noOp:
            return
        case .restoreBase:
            pendingHide = nil
            pendingExpiryKind = nil
            overlayMode = nil
            if baseMode != nil {
                controllerVisible = true
                renderActivePresentation()
            } else {
                hide()
            }
        case .hideAll:
            hide()
        }
    }

    private func cancelOverlayTimer() {
        pendingHide?.cancel()
        pendingHide = nil
        pendingExpiryKind = nil
        timerGeneration &+= 1
    }

    private func renderActivePresentation() {
        guard controllerVisible,
              let mode = NotchpadPresentationLogic.displayedMode(base: baseMode, overlay: overlayMode)
        else {
            updateConnector()
            return
        }

        let descriptors = settings.notchpadEnabled ? NotchScreenSnapshot.descriptors() : []
        let routing = NotchpadPresentationLogic.routingSnapshot(
            enabled: settings.notchpadEnabled,
            descriptors: descriptors
        )
        let geometry = routing.geometry
        let nextStyle = routing.surfaceStyle
        logRoutingTransitionIfNeeded(snapshot: routing)
        surfaceStyle = nextStyle
        lastResolvedGeometry = geometry

        let positionSurface = positionSurface(for: mode)
        let callbacks = makeCallbacks()
        let allowsDrag = nextStyle == .floating
        let hosting = NSHostingView(rootView: HUDView(
            mode: mode,
            surfaceStyle: nextStyle,
            onPillClick: { [weak self] in self?.onPillClick?() },
            panelCallbacks: callbacks,
            onBackgroundDragStarted: allowsDrag
                ? { [weak self] in self?.panelDragState.begin() }
                : {},
            onBackgroundDragCompleted: allowsDrag
                ? { [weak self] in
                    guard let self else { return }
                    self.panelDragState.finish(
                        capturePlacementContext: FloatingPanelPlacementPolicy.captureContext,
                        persist: { context in
                            self.persistPanelPosition(for: positionSurface, placementContext: context)
                        }
                    )
                }
                : {}
        ))
        let fitting = hosting.fittingSize
        let size = NSSize(width: max(fitting.width, 60), height: max(fitting.height, 36))
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
            panel.contentView = hosting
            panel.setContentSize(size)
        } else {
            panel = Self.makePanel(size: size, surfaceStyle: nextStyle)
            panel.contentView = hosting
            self.panel = panel
        }
        Self.applySurfaceStyle(nextStyle, to: panel)
        position(panel, for: positionSurface, style: nextStyle, geometry: geometry)
        panel.orderFrontRegardless()
        updateConnector()
    }

    /// Builds the same callback bundle used by every surface; kept internal for headless parity
    /// tests without requiring SwiftUI/AppKit control automation.
    func makeCallbacks() -> PanelCallbacks {
        PanelCallbacks(
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
    }

    // MARK: Panel policy

    static func makePanel(size: NSSize, surfaceStyle: SurfaceStyle = .floating) -> NSPanel {
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        applySurfaceStyle(surfaceStyle, to: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The HUD must receive control taps without becoming key or moving for arbitrary clicks.
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        return panel
    }

    static func applySurfaceStyle(_ style: SurfaceStyle, to panel: NSPanel) {
        switch style {
        case .floating:
            panel.level = .floating
        case .notch:
            panel.level = .statusBar
        }
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    }

    // MARK: Connector (notch only, noninteractive)

    private func updateConnector() {
        let shouldShow = NotchpadPresentationLogic.connectorShouldBeVisible(
            controllerVisible: controllerVisible,
            surfaceStyle: surfaceStyle
        )
        guard shouldShow, let geometry = lastResolvedGeometry else {
            connectorPanel?.orderOut(nil)
            connectorPanel = nil
            return
        }

        let frame = geometry.connectorFrame
        let connector: NSPanel
        if let existing = connectorPanel {
            connector = existing
            connector.setFrame(frame, display: true)
        } else {
            connector = Self.makeConnectorPanel(frame: frame)
            connectorPanel = connector
        }
        Self.applySurfaceStyle(.notch, to: connector)
        connector.orderFrontRegardless()
    }

    static func makeConnectorPanel(frame: CGRect) -> NSPanel {
        let panel = HUDPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.setFrame(frame, display: false)
        return panel
    }

    // MARK: Geometry + routing

    private func handleRoutingEnvironmentChange() {
        // While hidden, routing events are no-ops (no resurrection).
        guard controllerVisible else { return }
        // Reroute does NOT invalidate the overlay timer — same generation stays valid.
        renderActivePresentation()
    }

    private func logRoutingTransitionIfNeeded(
        snapshot: NotchpadPresentationLogic.RoutingSnapshot
    ) {
        let style = snapshot.surfaceStyle
        let displayID = snapshot.displayID
        let isBuiltin = snapshot.isBuiltin
        let rejection = snapshot.rejection

        let surfaceChanged = lastLoggedSurface != style
        let displayChanged = lastLoggedDisplayID != displayID
        let builtinChanged = lastLoggedBuiltin != isBuiltin
        let rejectionChanged = lastLoggedRejection != rejection

        guard surfaceChanged || displayChanged || builtinChanged || rejectionChanged else {
            return
        }

        let handoff: String
        if let previous = lastLoggedSurface, previous != style {
            handoff = "\(previous)->\(style)"
        } else {
            handoff = "none"
        }

        Self.logger.info(
            """
            notchpad route surface=\(String(describing: style), privacy: .public) \
            displayID=\(displayID.map(String.init) ?? "nil", privacy: .public) \
            builtin=\(isBuiltin.map(String.init) ?? "nil", privacy: .public) \
            rejection=\(rejection ?? "none", privacy: .public) \
            handoff=\(handoff, privacy: .public) \
            visible=\(self.controllerVisible, privacy: .public)
            """
        )

        lastLoggedSurface = style
        lastLoggedDisplayID = displayID
        lastLoggedBuiltin = isBuiltin
        lastLoggedRejection = rejection
    }

    // MARK: Positioning

    private func position(
        _ panel: NSPanel,
        for surface: PositionSurface,
        style: SurfaceStyle,
        geometry: NotchGeometry?
    ) {
        switch style {
        case .notch:
            guard let geometry else {
                positionFloating(panel, for: surface)
                return
            }
            let size = panel.frame.size
            let origin = CGPoint(
                x: geometry.notchFrame.midX - size.width / 2,
                y: geometry.contentOriginY(panelHeight: size.height)
            )
            // Center under notch; clamp X to screen so wide recording rows stay on-display.
            let clampedX = min(
                max(origin.x, geometry.screenFrame.minX),
                geometry.screenFrame.maxX - size.width
            )
            panel.setFrameOrigin(CGPoint(x: clampedX, y: origin.y))
        case .floating:
            positionFloating(panel, for: surface)
        }
    }

    private func positionFloating(_ panel: NSPanel, for surface: PositionSurface) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let placementContext = FloatingPanelPlacementPolicy.captureContext()
        let displays = placementContext.displays
        let fallback = Self.displayFrame(screen, in: placementContext)
        let saved = savedPosition(for: surface)
        let restoredOrigin: CGPoint
        if let saved {
            restoredOrigin = FloatingPanelGeometry.restoredOrigin(
                saved: saved,
                displays: displays,
                fallback: fallback,
                panelSize: panel.frame.size
            )
        } else {
            let placementFrame = fallback.visibleFrame
            switch surface {
            case .recording:
                restoredOrigin = FloatingPanelGeometry.launcherFrame(
                    edge: settings.edgeLauncherEdge,
                    position: settings.edgeLauncherPosition,
                    panelSize: panel.frame.size,
                    visibleFrame: placementFrame
                ).origin
            case .transient:
                restoredOrigin = FloatingPanelGeometry.clampedOrigin(
                    CGPoint(
                        x: placementFrame.midX - panel.frame.width / 2,
                        y: placementFrame.minY + 90
                    ),
                    panelSize: panel.frame.size,
                    visibleFrame: placementFrame
                )
            }
        }
        panel.setFrameOrigin(panelDragState.originForRender(
            liveOrigin: panel.frame.origin,
            restoredOrigin: restoredOrigin
        ))
    }

    private func savedPosition(for surface: PositionSurface) -> NormalizedWindowPosition? {
        switch surface {
        case .recording:
            settings.recordingHUDPosition
        case .transient:
            settings.transientHUDPosition
        }
    }

    private func positionSurface(for mode: Mode) -> PositionSurface {
        if case .recordingPanel = mode {
            return .recording
        } else {
            return .transient
        }
    }

    private func persistPanelPosition(
        for surface: PositionSurface,
        placementContext: FloatingPanelPlacementContext
    ) {
        guard surfaceStyle == .floating else { return }
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let display = Self.displayFrame(screen, in: placementContext)
        panel.setFrameOrigin(FloatingPanelGeometry.clampedOrigin(
            panel.frame.origin,
            panelSize: panel.frame.size,
            visibleFrame: display.visibleFrame
        ))
        let position = FloatingPanelGeometry.normalizedOrigin(
            frame: panel.frame,
            display: display
        )
        switch surface {
        case .recording:
            settings.recordingHUDPosition = position
        case .transient:
            settings.transientHUDPosition = position
        }
    }

    private static func displayFrame(
        _ screen: NSScreen,
        in placementContext: FloatingPanelPlacementContext
    ) -> DisplayFrame {
        let id = FloatingPanelPlacementPolicy.displayID(for: screen)
        return placementContext.display(id: id)
            ?? DisplayFrame(id: id, visibleFrame: screen.visibleFrame)
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

// MARK: - Views

/// Surface-agnostic mode content (no drag, no chrome).
struct HUDModeContent: View {
    let mode: HUDController.Mode
    var onPillClick: () -> Void = {}
    var panelCallbacks: HUDController.PanelCallbacks = .init()

    var body: some View {
        Group {
            switch mode {
            case .text(let text):
                Text(text)
                    .lineLimit(Self.lineLimit(for: text))
                    .truncationMode(.head)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320, maxHeight: .infinity)
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
                    if let errorText = presentation.errorText {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    HStack(spacing: 8) {
                        Button(presentation.retryTitle, action: panelCallbacks.onRetryTranslation)
                            .disabled(!presentation.actionsEnabled)
                        Button(presentation.insertSourceTitle, action: panelCallbacks.onInsertSourceText)
                            .disabled(!presentation.actionsEnabled)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
        }
        .font(.system(size: 13, weight: .medium))
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
                languageOptions: state.languageOptions,
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

struct HUDView: View {
    let mode: HUDController.Mode
    var surfaceStyle: HUDController.SurfaceStyle = .floating
    var onPillClick: () -> Void = {}
    var panelCallbacks: HUDController.PanelCallbacks = .init()
    var onBackgroundDragStarted: () -> Void = {}
    var onBackgroundDragCompleted: () -> Void = {}

    var body: some View {
        let content = HUDModeContent(
            mode: mode,
            onPillClick: onPillClick,
            panelCallbacks: panelCallbacks
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)

        switch surfaceStyle {
        case .floating:
            content
                .background(HUDDragSurface(
                    onDragStarted: onBackgroundDragStarted,
                    onDragCompleted: onBackgroundDragCompleted
                ))
                .background(.regularMaterial, in: Capsule())
        case .notch:
            // No drag; rounded rect fused under the notch strip rather than free-floating capsule.
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// Back-compat for existing tests that call `HUDView.lineLimit`.
    nonisolated static func lineLimit(for text: String) -> Int? {
        HUDModeContent.lineLimit(for: text)
    }
}

private struct HUDDragSurface: NSViewRepresentable {
    let onDragStarted: () -> Void
    let onDragCompleted: () -> Void

    func makeNSView(context: Context) -> HUDDragView {
        HUDDragView(onDragStarted: onDragStarted, onDragCompleted: onDragCompleted)
    }

    func updateNSView(_ view: HUDDragView, context: Context) {
        view.onDragStarted = onDragStarted
        view.onDragCompleted = onDragCompleted
    }
}

private final class HUDDragView: NSView {
    var onDragStarted: () -> Void
    var onDragCompleted: () -> Void

    init(onDragStarted: @escaping () -> Void, onDragCompleted: @escaping () -> Void) {
        self.onDragStarted = onDragStarted
        self.onDragCompleted = onDragCompleted
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onDragStarted()
        defer { onDragCompleted() }
        window.performDrag(with: event)
    }
}
