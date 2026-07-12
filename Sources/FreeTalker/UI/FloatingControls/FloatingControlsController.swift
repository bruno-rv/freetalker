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
    }

    private let settings: AppSettings
    private let callbacks: Callbacks
    private var panel: NSPanel?
    private var hostingView: FloatingControlsHostingView?
    private var state = FloatingControlsHoverState.collapsed
    private var collapseWorkItem: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var screenObserver: FloatingControlsObserverToken?

    init(settings: AppSettings = .shared, callbacks: Callbacks) {
        self.settings = settings
        self.callbacks = callbacks
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
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled, _, _ in
                guard let self else { return }
                if enabled { self.show() } else { self.hideForDisabledSetting() }
            }
            .store(in: &cancellables)
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
    }

    func screenConfigurationDidChange() {
        guard settings.edgeLauncherEnabled else { return }
        renderAndPosition()
        hostingView?.reinstallTrackingArea()
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
        panel?.orderFrontRegardless()
    }

    private func hideForDisabledSetting() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        state.reduce(.settingDisabled)
        panel?.orderOut(nil)
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
        let view = FloatingControlsView(
            state: state,
            edge: settings.edgeLauncherEdge,
            languagePin: settings.languagePin,
            callbacks: callbacks
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

private final class FloatingControlsHostingView: NSHostingView<FloatingControlsView> {
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
}
