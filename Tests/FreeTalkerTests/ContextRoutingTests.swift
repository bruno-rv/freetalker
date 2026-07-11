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
        (ContextCaptureLimitation.screenRecordingPermissionNotDetermined, "Allow Screen Recording in Settings for Window + local OCR"),
        (.screenRecordingPermissionDenied, "Screen Recording permission denied for Window + local OCR"),
        (.screenCaptureTargetUnavailable, "Stopped window is no longer available for local OCR"),
        (.screenCaptureFailed, "Window capture failed; continuing without local OCR")
    ])
    func everyOCRLimitationHasVisibleHint(_ limitation: ContextCaptureLimitation, _ hint: String) {
        #expect(AppCoordinator.contextPermissionHint(for: limitation) == hint)
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
        #expect(result.ruleFired)
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
        #expect(!result.ruleFired)
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
