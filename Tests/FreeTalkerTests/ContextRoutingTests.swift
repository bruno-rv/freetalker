import Foundation
import Testing
@testable import FreeTalker

@MainActor
@Suite struct ContextRoutingTests {
    @Test func approvedScopeIsCapturedExactlyOnceAtStop() {
        let provider = CountingContextProvider()

        let target = ContextTargetSnapshot(appName: "Mail", bundleID: "com.apple.mail", processID: 41, windowID: 77, windowTitle: "Draft")
        let capture = AppCoordinator.captureApprovedContext(scope: .focusedField, target: target, provider: provider)

        #expect(provider.scopes == [.focusedField])
        #expect(provider.targets == [target])
        #expect(capture.context.text == "approved")
    }

    @Test func offDoesNotCallContextProvider() {
        let provider = CountingContextProvider()

        let target = ContextTargetSnapshot(appName: "Mail", bundleID: "com.apple.mail", processID: 41, windowID: 77, windowTitle: nil)
        let capture = AppCoordinator.captureApprovedContext(scope: .off, target: target, provider: provider)

        #expect(provider.scopes.isEmpty)
        #expect(capture == .empty)
    }

    @Test func cloudRouteNeverAttachesCapturedContext() {
        #expect(AppCoordinator.localContextForProcessor(isCloudConfigured: true, capture: .approved) == nil)
    }

    @Test func localRouteAttachesCapturedContext() {
        #expect(AppCoordinator.localContextForProcessor(isCloudConfigured: false, capture: .approved)?.text == "approved")
    }

    @Test func permissionFallbackKeepsIdentityAndProvidesVisibleHint() {
        let capture = ContextCapture(
            context: .init(appName: "Mail", bundleID: "com.apple.mail", windowTitle: nil, text: ""),
            limitation: .accessibilityPermissionRequired
        )

        #expect(AppCoordinator.contextPermissionHint(for: capture.limitation) == "Accessibility permission required for Local context")
        #expect(capture.context.appName == "Mail")
    }

    @Test(arguments: [
        (ContextCaptureLimitation.screenRecordingPermissionNotGranted, "Screen Recording not granted for Window + local OCR"),
        (.screenCaptureTargetUnavailable, "Stopped window is no longer available for local OCR"),
        (.screenCaptureFailed, "Window capture failed; continuing without local OCR")
    ])
    func everyOCRLimitationHasVisibleHint(_ limitation: ContextCaptureLimitation, _ hint: String) {
        #expect(AppCoordinator.contextPermissionHint(for: limitation) == hint)
    }

    /// The reported shape: an App Rule for Warp plus a cloud LLM. Neither consumer of the OCR text
    /// exists, so the screenshot + Vision pass must not run at all.
    @Test func appRuleAndCloudProcessorSkipWindowOCR() {
        #expect(
            AppCoordinator.windowOCRHasConsumer(
                scope: .windowOCR,
                bundleID: "dev.warp.Warp-Stable",
                rules: ["dev.warp.Warp-Stable": "manual"],
                templates: [Template(id: "manual", name: "Manual", prompt: "Manual")],
                activeTemplateID: "manual",
                automaticStyleEnabled: true,
                processorReadsLocalContext: false
            ) == false
        )
    }

    @Test func automaticStyleWithoutAppRuleStillPaysForWindowOCR() {
        #expect(
            AppCoordinator.windowOCRHasConsumer(
                scope: .windowOCR,
                bundleID: "com.example.unknown",
                rules: [:],
                templates: [Template(id: "manual", name: "Manual", prompt: "Manual")],
                activeTemplateID: "manual",
                automaticStyleEnabled: true,
                processorReadsLocalContext: false
            )
        )
    }

    /// `AppleFMProcessor` is handed the text itself, so it needs the capture even when an App Rule
    /// has already settled the template.
    @Test func localProcessorNeedsWindowOCREvenUnderAnAppRule() {
        #expect(
            AppCoordinator.windowOCRHasConsumer(
                scope: .windowOCR,
                bundleID: "dev.warp.Warp-Stable",
                rules: ["dev.warp.Warp-Stable": "manual"],
                templates: [Template(id: "manual", name: "Manual", prompt: "Manual")],
                activeTemplateID: "manual",
                automaticStyleEnabled: false,
                processorReadsLocalContext: true
            )
        )
    }

    @Test(arguments: [LocalContextScope.off, .activeWindow, .focusedField])
    func nonOCRScopesNeverCaptureTheWindow(_ scope: LocalContextScope) {
        #expect(
            AppCoordinator.windowOCRHasConsumer(
                scope: scope,
                bundleID: "com.example.unknown",
                rules: [:],
                templates: [Template(id: "manual", name: "Manual", prompt: "Manual")],
                activeTemplateID: "manual",
                automaticStyleEnabled: true,
                processorReadsLocalContext: true
            ) == false
        )
    }

    @Test func manualRuleWinsLocalAutomaticStyle() {
        let manual = Template(id: "manual", name: "Manual", prompt: "Manual")
        let active = Template(id: "active", name: "Active", prompt: "Active")
        let capture = ContextCapture(
            context: .init(appName: "Mail", bundleID: "com.apple.mail", windowTitle: "Reply", text: "email"),
            limitation: nil
        )

        let result = AppCoordinator.resolveContextAwareTemplate(
            automaticStyleEnabled: true,
            capture: capture,
            rules: ["com.apple.mail": manual.id],
            templates: [manual, active] + Template.builtIns,
            activeTemplateID: active.id
        )

        #expect(result.template == manual)
        #expect(result.source == .appRule)
    }

    @Test func automaticStyleOffUsesActiveTemplate() {
        let active = Template(id: "active", name: "Active", prompt: "Active")

        let result = AppCoordinator.resolveContextAwareTemplate(
            automaticStyleEnabled: false,
            capture: .approved,
            rules: [:],
            templates: [active] + Template.builtIns,
            activeTemplateID: active.id
        )

        #expect(result.template == active)
        #expect(result.source == .activeTemplate)
    }

    /// The defect this guards: `AutomaticStyleClassifier.classify` always returns a style, and
    /// every style maps to a built-in that is always present, so with automatic style on and no
    /// App Rule the Active Template is unreachable — the panel must name the style's template and
    /// say why, never the selection that cannot run.
    @Test func recordingPanelNamesTheAutomaticStylePickNotTheActiveTemplate() {
        let active = Template(id: "prompt-engineer-opus-4-8", name: "Prompt Engineer (Opus 5)", prompt: "Opus")

        let panel = AppCoordinator.recordingPanelTemplate(
            bundleID: "com.unknown.editor",
            rules: [:],
            templates: Template.builtIns,
            activeTemplateID: active.id,
            automaticStyleEnabled: true
        )

        #expect(panel.name == "Clean Dictation")
        #expect(panel.overrideHint?.contains("Prompt Engineer (Opus 5)") == true)
        #expect(panel.overrideHint?.contains("Automatically choose template") == true)
    }

    @Test func recordingPanelNamesTheAppRulePickWithItsReason() {
        let manual = Template(id: "manual", name: "Manual", prompt: "Manual")
        let active = Template(id: "active", name: "Active", prompt: "Active")

        let panel = AppCoordinator.recordingPanelTemplate(
            bundleID: "com.apple.mail",
            rules: ["com.apple.mail": manual.id],
            templates: [manual, active] + Template.builtIns,
            activeTemplateID: active.id,
            automaticStyleEnabled: true
        )

        #expect(panel.name == "Manual")
        #expect(panel.overrideHint?.contains("App Rule") == true)
        #expect(panel.overrideHint?.contains("Active") == true)
    }

    @Test func destinationFallsBackToTheLastNonSelfAppOnlyWhenFreeTalkerIsFrontmost() {
        #expect(AppCoordinator.destinationBundleID(
            frontmost: "com.apple.mail", selfBundleID: "org.freetalker.app", lastNonSelf: "com.tinyspeck.slackmacgap"
        ) == "com.apple.mail")
        #expect(AppCoordinator.destinationBundleID(
            frontmost: "org.freetalker.app", selfBundleID: "org.freetalker.app", lastNonSelf: "com.tinyspeck.slackmacgap"
        ) == "com.tinyspeck.slackmacgap")
        #expect(AppCoordinator.destinationBundleID(
            frontmost: nil, selfBundleID: "org.freetalker.app", lastNonSelf: nil
        ) == nil)
    }

    @Test func recordingPanelHasNoOverrideHintWhenTheActiveTemplateRuns() {
        let active = Template(id: "active", name: "Active", prompt: "Active")

        let panel = AppCoordinator.recordingPanelTemplate(
            bundleID: "com.apple.mail",
            rules: [:],
            templates: [active] + Template.builtIns,
            activeTemplateID: active.id,
            automaticStyleEnabled: false
        )

        #expect(panel.name == "Active")
        #expect(panel.overrideHint == nil)
    }

    @Test func automaticStyleDefaultsOffAndPersists() {
        let suite = "ContextRoutingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var settings: AppSettings? = AppSettings(defaults: defaults)
        #expect(settings?.automaticStyleEnabled == false)
        settings?.automaticStyleEnabled = true
        settings = AppSettings(defaults: defaults)
        #expect(settings?.automaticStyleEnabled == true)
    }
}

@MainActor
private final class CountingContextProvider: LocalContextProvider {
    var scopes: [LocalContextScope] = []
    var targets: [ContextTargetSnapshot] = []

    func capture(scope: LocalContextScope, target: ContextTargetSnapshot) -> ContextCapture {
        scopes.append(scope)
        targets.append(target)
        return .approved
    }
}

private extension ContextCapture {
    static let approved = ContextCapture(
        context: .init(appName: "Mail", bundleID: "com.apple.mail", windowTitle: "Reply", text: "approved"),
        limitation: nil
    )
}
