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
    /// While a recording is active the HUD's recording panel takes over this same edge-anchored
    /// spot (see `HUDController.launcherAnchoredFrame`) — showing both at once would double up
    /// on the same corner of the screen.
    private let isRecording: () -> Bool
    private var panel: NSPanel?
    private var hostingView: FloatingControlsHostingView?
    /// Tracks whether `panel` is currently ordered front, so `renderAndPosition()` only calls
    /// `orderFrontRegardless()` on the show/reappear transitions. Re-asserting front-ordering on
    /// every hover-driven or AppCoordinator-driven re-render (this runs constantly while
    /// recording/processing) confuses the hosting view's tracking area and can leave the
    /// launcher stuck expanded — see the "hover never collapses" regression.
    private var isPanelVisible = false
    private var state = FloatingControlsHoverState.collapsed
    private var collapseWorkItem: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var screenObserver: FloatingControlsObserverToken?
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
        settings.$edgeLauncherEnabled
            .combineLatest(settings.$edgeLauncherEdge, settings.$edgeLauncherPosition)
            .combineLatest(settings.$languagePin)
            .sink { [weak self] launcherSettings, languagePin in
                guard let self else { return }
                let (enabled, _, _) = launcherSettings
                self.presentedLanguagePin = languagePin
                self.refreshTranslationState()
                if enabled { self.show() } else { self.hideForDisabledSetting() }
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
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        state = .collapsed
        isPanelVisible = false
    }

    func screenConfigurationDidChange() {
        guard settings.edgeLauncherEnabled else { return }
        renderAndPosition()
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
        if settings.edgeLauncherEnabled { renderAndPosition() }
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
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return panel
    }

    private func show() {
        if panel == nil {
            panel = Self.makePanel(size: CGSize(width: 18, height: 64))
        }
        renderAndPosition()
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
        renderAndPosition()
        hostingView?.reinstallTrackingArea()
    }

    private func pointerExited() {
        state.reduce(.pointerExited)
        collapseWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.state.reduce(.collapseDelayElapsed)
            self.renderAndPosition()
            self.hostingView?.reinstallTrackingArea()
        }
        collapseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    private func renderAndPosition() {
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
            translationState: presentedTranslationState,
            callbacks: viewCallbacks
        )
        let hosting = FloatingControlsHostingView(rootView: view)
        hosting.onPointerEntered = { [weak self] in self?.pointerEntered() }
        hosting.onPointerExited = { [weak self] in self?.pointerExited() }
        let fitting = hosting.fittingSize
        let size = CGSize(width: max(fitting.width, 14), height: max(fitting.height, 14))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setContentSize(size)
        hostingView = hosting

        guard let screen = screenForLauncher() else { return }
        panel.setFrame(FloatingPanelGeometry.launcherFrame(
            edge: settings.edgeLauncherEdge,
            position: settings.edgeLauncherPosition,
            panelSize: size,
            visibleFrame: screen.visibleFrame
        ), display: true)
        hosting.reinstallTrackingArea()
        if !isPanelVisible {
            panel.orderFrontRegardless()
            isPanelVisible = true
        }
    }

    private func screenForLauncher() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? panel?.screen ?? NSScreen.main
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
}
