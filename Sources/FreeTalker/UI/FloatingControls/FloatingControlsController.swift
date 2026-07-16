import AppKit
import Combine
import SwiftUI

enum FloatingControlsHoverState: Equatable {
    case collapsed
    case revealed
    case expanded
    case scheduledCollapse

    enum Event {
        case pointerEntered
        case pointerExited
        case childControlEntered
        case settingDisabled
        case expansionCompleted
        case collapseDelayElapsed
    }

    var isCollapseScheduled: Bool { self == .scheduledCollapse }

    mutating func reduce(_ event: Event) {
        switch event {
        case .pointerEntered, .childControlEntered:
            self = self == .collapsed ? .revealed : .expanded
        case .pointerExited:
            if self != .collapsed { self = .scheduledCollapse }
        case .settingDisabled, .collapseDelayElapsed:
            self = .collapsed
        case .expansionCompleted:
            if self == .revealed { self = .expanded }
        }
    }
}

@MainActor
final class FloatingControlsController {
    struct Callbacks {
        var onDictation: () -> Void
        var onScratchpad: () -> Void
        var onOpenSettings: () -> Void
        var onLanguage: (String) -> Void
        var onOutput: (OutputLanguage) -> Void
    }

    private let settings: AppSettings
    private let callbacks: Callbacks
    private let outputSelection: () -> RecordingOutputSelection
    private let outputUpdates: AnyPublisher<Void, Never>
    private let cloudSnapshot: () -> CloudLLMSettingsSnapshot
    private let notificationCenter: NotificationCenter
    /// The launcher hides while recording so it never competes with the recording HUD.
    private let isRecording: () -> Bool
    private var panel: NSPanel?
    private var hostingView: FloatingControlsHostingView?
    /// Tracks whether `panel` is currently ordered front, so `renderAndPosition()` only calls
    /// `orderFrontRegardless()` on the show/reappear transitions. Re-asserting front-ordering on
    /// every hover-driven or AppCoordinator-driven re-render (this runs constantly while
    /// recording/processing) confuses the hosting view's tracking area and can leave the
    /// launcher stuck expanded — see the "hover never collapses" regression.
    ///
    /// `renderAndPosition()` also reuses `hostingView` across re-renders instead of replacing
    /// `panel.contentView` every time: destroying the hosting view while the cursor is inside its
    /// tracking area (which happens on every `pointerEntered()`-triggered render) tears down that
    /// tracking area without AppKit ever delivering a matching `mouseExited`, so `pointerExited()`
    /// never runs and the collapse timer never gets scheduled. The tracking area itself uses
    /// `.inVisibleRect`, so it already follows the view's bounds across resizes — it only needs to
    /// be (re)installed when the hosting view is first created.
    private var isPanelVisible = false
    private let panelDragState = FloatingPanelDragState()
    private var state = FloatingControlsHoverState.collapsed
    private var collapseWorkItem: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var screenObserver: FloatingControlsObserverToken?
    private var activeSpaceObserver: FloatingControlsObserverToken?
    private(set) var presentedLanguagePin: String?
    private(set) var presentedTranslationState: TranslationControlsState

    init(
        settings: AppSettings = .shared,
        outputSelection: @escaping () -> RecordingOutputSelection = { RecordingOutputSelection() },
        outputUpdates: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher(),
        cloudSnapshot: (() -> CloudLLMSettingsSnapshot)? = nil,
        notificationCenter: NotificationCenter = .default,
        isRecording: @escaping () -> Bool = { false },
        callbacks: Callbacks
    ) {
        self.settings = settings
        self.outputSelection = outputSelection
        self.outputUpdates = outputUpdates
        self.cloudSnapshot = cloudSnapshot ?? { settings.cloudLLMSnapshot }
        self.notificationCenter = notificationCenter
        self.isRecording = isRecording
        self.callbacks = callbacks
        presentedLanguagePin = settings.languagePin
        presentedTranslationState = Self.translationState(
            settings: settings,
            selection: outputSelection(),
            snapshot: (cloudSnapshot ?? { settings.cloudLLMSnapshot })()
        )
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver.value) }
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver.value)
        }
    }

    func start() {
        guard screenObserver == nil else { return }
        screenObserver = FloatingControlsObserverToken(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screenConfigurationDidChange() }
        })
        activeSpaceObserver = FloatingControlsObserverToken(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.screenConfigurationDidChange() }
            }
        )
        settings.$edgeLauncherEnabled
            .combineLatest(settings.$launcherPanelPosition)
            .combineLatest(settings.$languagePin)
            .sink { [weak self] launcherSettings, languagePin in
                guard let self else { return }
                let (enabled, savedPosition) = launcherSettings
                self.presentedLanguagePin = languagePin
                self.refreshTranslationState()
                if enabled {
                    self.show(savedPosition: savedPosition)
                } else {
                    self.hideForDisabledSetting()
                }
            }
            .store(in: &cancellables)
        let configurationUpdates = Publishers.CombineLatest4(
            settings.$defaultOutputLanguage,
            settings.$llmProvider,
            settings.$cloudLLMBaseURL,
            settings.$cloudLLMModel
        ).dropFirst().map { _ in () }.eraseToAnyPublisher()
        Publishers.Merge(outputUpdates, configurationUpdates)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            DispatchQueue.main.async { self?.refreshOutputPresentation() }
        }
        .store(in: &cancellables)
        notificationCenter.publisher(for: .cloudLLMCredentialsDidChange)
            .sink { [weak self] _ in self?.refreshOutputPresentation() }
            .store(in: &cancellables)
        refreshOutputPresentation()
    }

    func stop() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        cancellables.removeAll()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver.value)
            self.screenObserver = nil
        }
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver.value)
            self.activeSpaceObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        state = .collapsed
        isPanelVisible = false
    }

    func screenConfigurationDidChange() {
        guard settings.edgeLauncherEnabled else { return }
        renderAndPosition(savedPosition: settings.launcherPanelPosition)
        hostingView?.reinstallTrackingArea()
    }

    func selectOutput(_ language: OutputLanguage) {
        callbacks.onOutput(language)
        refreshOutputPresentation()
    }

    private static func translationState(
        settings: AppSettings,
        selection: RecordingOutputSelection,
        snapshot: CloudLLMSettingsSnapshot
    ) -> TranslationControlsState {
        return TranslationControlsState(
            effectiveOutput: selection.effective ?? settings.defaultOutputLanguage,
            override: selection.effective,
            availability: .make(eligibility: snapshot.eligibility, provider: snapshot.provider)
        )
    }

    private func refreshTranslationState() {
        presentedTranslationState = Self.translationState(
            settings: settings,
            selection: outputSelection(),
            snapshot: cloudSnapshot()
        )
    }

    private func refreshOutputPresentation() {
        refreshTranslationState()
        if settings.edgeLauncherEnabled {
            renderAndPosition(savedPosition: settings.launcherPanelPosition)
        }
    }

    static func makePanel(size: NSSize) -> NSPanel {
        let panel = FloatingControlsPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return panel
    }

    private func show(savedPosition: NormalizedWindowPosition?) {
        if panel == nil {
            panel = Self.makePanel(size: CGSize(width: 18, height: 64))
        }
        renderAndPosition(savedPosition: savedPosition)
    }

    private func hideForDisabledSetting() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        state.reduce(.settingDisabled)
        panel?.orderOut(nil)
        isPanelVisible = false
    }

    private func pointerEntered() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        state.reduce(.pointerEntered)
        state.reduce(.expansionCompleted)
        renderAndPosition(savedPosition: settings.launcherPanelPosition)
    }

    private func pointerExited() {
        state.reduce(.pointerExited)
        collapseWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.state.reduce(.collapseDelayElapsed)
            self.renderAndPosition(savedPosition: self.settings.launcherPanelPosition)
        }
        collapseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: item)
    }

    private func renderAndPosition(savedPosition: NormalizedWindowPosition?) {
        guard let panel else { return }
        guard !isRecording() else {
            panel.orderOut(nil)
            isPanelVisible = false
            return
        }
        var viewCallbacks = callbacks
        viewCallbacks.onOutput = { [weak self] language in self?.selectOutput(language) }
        let view = FloatingControlsView(
            state: state,
            edge: settings.edgeLauncherEdge,
            languagePin: presentedLanguagePin ?? settings.languagePin,
            languageOptions: settings.dictationLanguages,
            translationState: presentedTranslationState,
            callbacks: viewCallbacks
        )
        let hosting: FloatingControlsHostingView
        let isNewHostingView: Bool
        if let existing = hostingView, existing === panel.contentView {
            hosting = existing
            hosting.rootView = view
            isNewHostingView = false
        } else {
            hosting = FloatingControlsHostingView(rootView: view)
            panel.contentView = hosting
            hostingView = hosting
            isNewHostingView = true
        }
        hosting.onPointerEntered = { [weak self] in self?.pointerEntered() }
        hosting.onPointerExited = { [weak self] in self?.pointerExited() }
        hosting.allowsCollapsedDrag = state == .collapsed
        hosting.onCollapsedDragStarted = { [weak self] in self?.panelDragState.begin() }
        hosting.onCollapsedDragCompleted = { [weak self] in
            guard let self else { return }
            self.panelDragState.finish(
                capturePlacementContext: FloatingPanelPlacementPolicy.captureContext,
                persist: { context in
                    self.persistPanelPosition(placementContext: context)
                }
            )
        }
        let fitting = hosting.fittingSize
        let size = CGSize(width: max(fitting.width, 14), height: max(fitting.height, 14))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)

        guard let fallbackScreen = screenForLauncher() else { return }
        let placementContext = FloatingPanelPlacementPolicy.captureContext()
        let displays = placementContext.displays
        let fallback = Self.displayFrame(fallbackScreen, in: placementContext)
        let resolvedPosition: NormalizedWindowPosition
        if let savedPosition {
            resolvedPosition = savedPosition
        } else {
            let legacyPosition = FloatingPanelGeometry.legacyLauncherPosition(
                edge: settings.edgeLauncherEdge,
                position: settings.edgeLauncherPosition,
                panelSize: size,
                display: fallback
            )
            settings.launcherPanelPosition = legacyPosition
            resolvedPosition = legacyPosition
        }
        let restoredOrigin = FloatingPanelGeometry.restoredOrigin(
            saved: resolvedPosition,
            displays: displays,
            fallback: fallback,
            panelSize: size
        )
        panel.setFrameOrigin(panelDragState.originForRender(
            liveOrigin: panel.frame.origin,
            restoredOrigin: restoredOrigin
        ))
        if isNewHostingView { hosting.reinstallTrackingArea() }
        if !isPanelVisible {
            panel.orderFrontRegardless()
            isPanelVisible = true
        }
    }

    private func screenForLauncher() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? panel?.screen ?? NSScreen.main
    }

    private func persistPanelPosition(placementContext: FloatingPanelPlacementContext) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let display = Self.displayFrame(screen, in: placementContext)
        panel.setFrameOrigin(FloatingPanelGeometry.clampedOrigin(
            panel.frame.origin,
            panelSize: panel.frame.size,
            visibleFrame: display.visibleFrame
        ))
        settings.launcherPanelPosition = FloatingPanelGeometry.normalizedOrigin(
            frame: panel.frame,
            display: display
        )
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

private final class FloatingControlsObserverToken: @unchecked Sendable {
    let value: NSObjectProtocol
    init(_ value: NSObjectProtocol) { self.value = value }
}

private final class FloatingControlsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FloatingControlsHostingView: NSHostingView<FloatingControlsView> {
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?
    var onCollapsedDragStarted: (() -> Void)?
    var onCollapsedDragCompleted: (() -> Void)?
    var allowsCollapsedDrag = false
    private var pointerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        reinstallTrackingArea()
    }

    func reinstallTrackingArea() {
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) { onPointerEntered?() }
    override func mouseExited(with event: NSEvent) { onPointerExited?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        allowsCollapsedDrag ? self : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard allowsCollapsedDrag else {
            super.mouseDown(with: event)
            return
        }
        guard let window else { return }
        onCollapsedDragStarted?()
        defer { onCollapsedDragCompleted?() }
        window.performDrag(with: event)
    }
}
