import AppKit
import Testing
@testable import FreeTalker

@Suite @MainActor struct FloatingControlsPresentationTests {
    @Test func pointerEntryRevealsCollapsedLauncher() {
        var state = FloatingControlsHoverState.collapsed

        state.reduce(.pointerEntered)

        #expect(state == .revealed)
    }

    @Test func enteringChildControlKeepsExpandedLauncherOpen() {
        var state = FloatingControlsHoverState.expanded

        state.reduce(.pointerExited)
        state.reduce(.childControlEntered)

        #expect(state == .expanded)
    }

    @Test func reenterCancelsScheduledCollapse() {
        var state = FloatingControlsHoverState.expanded

        state.reduce(.pointerExited)
        #expect(state.isCollapseScheduled)
        state.reduce(.pointerEntered)

        #expect(state == .expanded)
    }

    @Test func disabledSettingHidesLauncherImmediately() {
        var state = FloatingControlsHoverState.expanded

        state.reduce(.settingDisabled)

        #expect(state == .collapsed)
    }

    @Test func panelNeverBecomesKeyOrMainAndJoinsFullScreenSpaces() {
        let panel = FloatingControlsController.makePanel(size: CGSize(width: 100, height: 40))

        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeKey == false)
        #expect(panel.canBecomeMain == false)
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @Test func hostingViewAcceptsFirstClickWithoutActivatingTheApp() {
        let view = FloatingControlsHostingView(rootView: FloatingControlsView(
            state: .collapsed,
            edge: .right,
            languagePin: "auto",
            callbacks: .init(
                onDictation: {},
                onScratchpad: {},
                onOpenSettings: {},
                onLanguage: { _ in }
            )
        ))

        #expect(view.acceptsFirstMouse(for: nil))
    }

    @Test func externalLanguageChangeRefreshesLauncherPresentation() {
        let suite = "FloatingControlsPresentationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.edgeLauncherEnabled = true
        let controller = FloatingControlsController(
            settings: settings,
            callbacks: .init(
                onDictation: {},
                onScratchpad: {},
                onOpenSettings: {},
                onLanguage: { settings.languagePin = $0 }
            )
        )
        controller.start()
        defer { controller.stop() }

        settings.languagePin = "pt"

        #expect(controller.presentedLanguagePin == "pt")
    }

    @Test(arguments: [
        (LauncherEdge.left, "Left", "Expands to the right, into the screen."),
        (.right, "Right", "Expands to the left, into the screen."),
        (.top, "Top", "Expands downward, into the screen."),
        (.bottom, "Bottom", "Expands upward, into the screen.")
    ])
    func launcherEdgePresentationIsExplicit(
        edge: LauncherEdge,
        name: String,
        explanation: String
    ) {
        #expect(edge.displayName == name)
        #expect(edge.explanation == explanation)
    }
}
