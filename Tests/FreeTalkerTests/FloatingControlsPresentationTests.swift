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
            translationState: .init(
                effectiveOutput: .sameAsSpoken,
                override: nil,
                availability: .init(enabled: true, tooltip: nil, accessibilityHelp: nil)
            ),
            callbacks: .init(
                onDictation: {},
                onScratchpad: {},
                onOpenSettings: {},
                onLanguage: { _ in },
                onOutput: { _ in }
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
                onLanguage: { settings.languagePin = $0 },
                onOutput: { _ in }
            )
        )
        controller.start()
        defer { controller.stop() }

        settings.languagePin = "pt"

        #expect(controller.presentedLanguagePin == "pt")
    }

    @Test func translationControlsUseExplicitLabelsAndCanonicalOutputOrder() {
        #expect(TranslationControlsPresentation.spokenLabel == "Speak:")
        #expect(TranslationControlsPresentation.outputLabel == "Output:")
        #expect(TranslationControlsPresentation.outputChoices.map(\.language) == OutputLanguage.allCases)
        #expect(TranslationControlsPresentation.outputChoices.map(\.label) == [
            "Same as spoken", "English", "Portuguese", "Mandarin Chinese", "Hindi",
            "Spanish", "Standard Arabic", "French", "German"
        ])
    }

    @Test func namedOutputsAreDisabledWithIdenticalHelpWhileSameRemainsEnabled() {
        let reason = "Add an API key in Settings."
        let state = TranslationControlsState(
            effectiveOutput: .sameAsSpoken,
            override: nil,
            availability: .init(enabled: false, tooltip: reason, accessibilityHelp: reason)
        )
        let presentation = TranslationControlsPresentation(state: state)

        #expect(presentation.isEnabled(.sameAsSpoken))
        #expect(OutputLanguage.allCases.dropFirst().allSatisfy { !presentation.isEnabled($0) })
        #expect(presentation.tooltip == reason)
        #expect(presentation.accessibilityHelp == reason)
        let policy = presentation.accessibilityPolicy(for: .german)
        #expect(policy.wrapperIsEnabled)
        #expect(!policy.childCommandIsEnabled)
        #expect(policy.label == "German")
        #expect(policy.value == "Unavailable")
        #expect(policy.hint == reason)
        #expect(policy.tooltip == reason)
    }

    @Test func outputSelectionCallbackKeepsPreRecordingOverrideSynchronized() {
        let suite = "FloatingControlsPresentationTests.output.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        var selection = RecordingOutputSelection()
        let controller = FloatingControlsController(
            settings: settings,
            outputSelection: { selection },
            callbacks: .init(
                onDictation: {}, onScratchpad: {}, onOpenSettings: {}, onLanguage: { _ in },
                onOutput: { selection.select($0, isRecording: false) }
            )
        )

        controller.selectOutput(.german)

        #expect(selection.pending == .german)
        #expect(controller.presentedTranslationState.override == .german)
        #expect(controller.presentedTranslationState.effectiveOutput == .german)
    }

    @Test func restartReinstallsOutputDefaultProviderAndCredentialSubscriptionsOnce() async {
        let suite = "FloatingControlsPresentationTests.restart.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let center = NotificationCenter()
        var selection = RecordingOutputSelection()
        var key: String?
        var outputCallbacks = 0
        var snapshotCalls = 0
        let controller = FloatingControlsController(
            settings: settings,
            outputSelection: { selection },
            cloudSnapshot: {
                snapshotCalls += 1
                return CloudLLMSettingsSnapshot(
                    provider: settings.llmProvider,
                    baseURL: settings.cloudLLMBaseURL,
                    model: settings.cloudLLMModel,
                    key: key,
                    vocabulary: []
                )
            },
            notificationCenter: center,
            callbacks: .init(
                onDictation: {}, onScratchpad: {}, onOpenSettings: {}, onLanguage: { _ in },
                onOutput: { outputCallbacks += 1; selection.select($0, isRecording: false) }
            )
        )
        controller.start()
        controller.stop()
        controller.start()

        controller.selectOutput(.german)
        #expect(outputCallbacks == 1)
        #expect(controller.presentedTranslationState.override == .german)

        selection.resolveTerminal()
        settings.defaultOutputLanguage = .french
        await waitUntil { controller.presentedTranslationState.effectiveOutput == .french }
        #expect(controller.presentedTranslationState.effectiveOutput == .french)

        settings.llmProvider = .anthropic
        settings.cloudLLMBaseURL = "https://api.anthropic.com/v1"
        settings.cloudLLMModel = "claude"
        await waitUntil { !controller.presentedTranslationState.availability.enabled }
        #expect(!controller.presentedTranslationState.availability.enabled)

        key = "saved"
        let callsBeforeCredential = snapshotCalls
        center.post(name: .cloudLLMCredentialsDidChange, object: nil)
        #expect(controller.presentedTranslationState.availability.enabled)
        #expect(snapshotCalls == callsBeforeCredential + 1)

        key = nil
        center.post(name: .cloudLLMCredentialsDidChange, object: nil)
        #expect(!controller.presentedTranslationState.availability.enabled)
        #expect(snapshotCalls == callsBeforeCredential + 2)
        controller.stop()
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
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
