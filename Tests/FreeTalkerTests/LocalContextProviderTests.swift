import Foundation
import Testing
@testable import FreeTalker

@MainActor
@Suite struct LocalContextProviderTests {
    @Test func offMakesNoAccessibilityCalls() {
        let adapter = FakeAccessibilityContext()
        let provider = AccessibilityLocalContextProvider(accessibility: adapter)

        let capture = provider.capture(scope: .off)

        #expect(capture == .empty)
        #expect(adapter.calls.isEmpty)
    }

    @Test func selectedTextCapturesOnlyTheSelection() {
        let adapter = FakeAccessibilityContext(
            identity: .init(appName: "Mail", bundleID: "com.apple.mail"),
            selectedText: "selected words",
            focusedField: .init(text: "entire draft", isSecure: false),
            activeWindow: .init(title: "Reply", visibleText: "whole window")
        )
        let provider = AccessibilityLocalContextProvider(accessibility: adapter)

        let capture = provider.capture(scope: .selectedText)

        #expect(capture.context == .init(appName: "Mail", bundleID: "com.apple.mail", windowTitle: nil, text: "selected words"))
        #expect(adapter.calls == [.identity, .permission, .selectedText])
    }

    @Test func focusedFieldCapturesEditableValueCappedAtEightThousandCharacters() {
        let adapter = FakeAccessibilityContext(
            identity: .init(appName: "Notes", bundleID: "com.apple.Notes"),
            focusedField: .init(text: String(repeating: "a", count: 8_001), isSecure: false)
        )
        let provider = AccessibilityLocalContextProvider(accessibility: adapter)

        let capture = provider.capture(scope: .focusedField)

        #expect(capture.context.text.count == 8_000)
        #expect(adapter.calls == [.identity, .permission, .focusedField])
    }

    @Test func secureFocusedFieldYieldsNoText() {
        let adapter = FakeAccessibilityContext(
            identity: .init(appName: "Browser", bundleID: "example.browser"),
            focusedField: .init(text: "secret", isSecure: true)
        )
        let provider = AccessibilityLocalContextProvider(accessibility: adapter)

        let capture = provider.capture(scope: .focusedField)

        #expect(capture.context.text.isEmpty)
    }

    @Test func activeWindowCapturesWindowTitleAndVisibleTextCappedAtTwelveThousandCharacters() {
        let adapter = FakeAccessibilityContext(
            identity: .init(appName: "Xcode", bundleID: "com.apple.dt.Xcode"),
            activeWindow: .init(title: "Editor", visibleText: String(repeating: "b", count: 12_001))
        )
        let provider = AccessibilityLocalContextProvider(accessibility: adapter)

        let capture = provider.capture(scope: .activeWindow)

        #expect(capture.context.windowTitle == "Editor")
        #expect(capture.context.text.count == 12_000)
        #expect(adapter.calls == [.identity, .permission, .activeWindow])
    }

    @Test func windowOCRCapturesMetadataButDoesNotReadAXText() {
        let adapter = FakeAccessibilityContext(
            identity: .init(appName: "Preview", bundleID: "com.apple.Preview"),
            activeWindow: .init(title: "Document", visibleText: "must not be read")
        )
        let provider = AccessibilityLocalContextProvider(accessibility: adapter)

        let capture = provider.capture(scope: .windowOCR)

        #expect(capture.context == .init(appName: "Preview", bundleID: "com.apple.Preview", windowTitle: "Document", text: ""))
        #expect(adapter.calls == [.identity, .permission, .windowMetadata])
    }

    @Test func missingPermissionReturnsAppIdentityAndTypedLimitationWithoutAXReads() {
        let adapter = FakeAccessibilityContext(
            trusted: false,
            identity: .init(appName: "Mail", bundleID: "com.apple.mail"),
            selectedText: "must not be read"
        )
        let provider = AccessibilityLocalContextProvider(accessibility: adapter)

        let capture = provider.capture(scope: .selectedText)

        #expect(capture.context == .init(appName: "Mail", bundleID: "com.apple.mail", windowTitle: nil, text: ""))
        #expect(capture.limitation == .accessibilityPermissionRequired)
        #expect(adapter.calls == [.identity, .permission])
    }

    @Test func contextScopePersistsAndDefaultsOff() {
        let suite = "LocalContextProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var settings: AppSettings? = AppSettings(defaults: defaults)
        #expect(settings?.localContextScope == .off)
        settings?.localContextScope = .activeWindow
        settings = AppSettings(defaults: defaults)
        #expect(settings?.localContextScope == .activeWindow)
    }
}

@MainActor
private final class FakeAccessibilityContext: AccessibilityContextProviding {
    enum Call: Equatable { case identity, permission, selectedText, focusedField, activeWindow, windowMetadata }

    let trusted: Bool
    let identityValue: AccessibilityAppIdentity
    let selectedTextValue: String?
    let focusedFieldValue: AccessibilityFocusedField?
    let activeWindowValue: AccessibilityWindow?
    var calls: [Call] = []

    init(
        trusted: Bool = true,
        identity: AccessibilityAppIdentity = .init(appName: nil, bundleID: nil),
        selectedText: String? = nil,
        focusedField: AccessibilityFocusedField? = nil,
        activeWindow: AccessibilityWindow? = nil
    ) {
        self.trusted = trusted
        identityValue = identity
        selectedTextValue = selectedText
        focusedFieldValue = focusedField
        activeWindowValue = activeWindow
    }

    func frontmostAppIdentity() -> AccessibilityAppIdentity { calls.append(.identity); return identityValue }
    func isTrusted() -> Bool { calls.append(.permission); return trusted }
    func selectedText() -> String? { calls.append(.selectedText); return selectedTextValue }
    func focusedField() -> AccessibilityFocusedField? { calls.append(.focusedField); return focusedFieldValue }
    func activeWindow() -> AccessibilityWindow? { calls.append(.activeWindow); return activeWindowValue }
    func activeWindowMetadata() -> AccessibilityWindowMetadata? {
        calls.append(.windowMetadata)
        return activeWindowValue.map { .init(title: $0.title) }
    }
}
