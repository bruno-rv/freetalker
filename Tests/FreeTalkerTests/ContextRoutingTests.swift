import Foundation
import Testing
@testable import FreeTalker

@MainActor
@Suite struct ContextRoutingTests {
    @Test func approvedScopeIsCapturedExactlyOnceAtStop() {
        let provider = CountingContextProvider()

        let capture = AppCoordinator.captureApprovedContext(scope: .focusedField, provider: provider)

        #expect(provider.scopes == [.focusedField])
        #expect(capture.context.text == "approved")
    }

    @Test func offDoesNotCallContextProvider() {
        let provider = CountingContextProvider()

        let capture = AppCoordinator.captureApprovedContext(scope: .off, provider: provider)

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

    func capture(scope: LocalContextScope) -> ContextCapture {
        scopes.append(scope)
        return .approved
    }
}

private extension ContextCapture {
    static let approved = ContextCapture(
        context: .init(appName: "Mail", bundleID: "com.apple.mail", windowTitle: "Reply", text: "approved"),
        limitation: nil
    )
}
