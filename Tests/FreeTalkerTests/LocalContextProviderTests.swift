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

    @Test func invalidPersistedScopeIsNormalizedToOff() {
        let suite = "LocalContextProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("future-invalid-scope", forKey: "localContextScope")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.localContextScope == .off)
        #expect(defaults.string(forKey: "localContextScope") == LocalContextScope.off.rawValue)
    }

    @Test func captureUsesOneApplicationSnapshotPIDForAllAXReads() {
        let adapter = FakeAccessibilityContext(
            identity: .init(appName: "Original", bundleID: "original.app", pid: 41),
            activeWindow: .init(title: "Original window", visibleText: "Original content")
        )
        adapter.identityAfterFirstRead = .init(appName: "Changed", bundleID: "changed.app", pid: 99)
        let provider = AccessibilityLocalContextProvider(accessibility: adapter)

        let capture = provider.capture(scope: .activeWindow)

        #expect(capture.context.appName == "Original")
        #expect(capture.context.text == "Original content")
        #expect(adapter.requestedPIDs == [41])
        #expect(adapter.calls.filter { $0 == .identity }.count == 1)
    }
}

@MainActor
@Suite struct AccessibilityTreeReaderTests {
    @Test func cycleVisitsEveryNodeAtMostOnce() {
        let adapter = FakeNodeAdapter(nodes: [
            1: .init(text: "one", children: [2]),
            2: .init(text: "two", children: [1])
        ])
        let reader = AccessibilityTreeReader(adapter: adapter)

        let text = reader.visibleText(root: 1)

        #expect(text == "one\ntwo")
        #expect(adapter.childrenReads == 2)
    }

    @Test func deepTreeStopsAtMaximumDepthWithoutRecursion() {
        var nodes: [Int: FakeNodeAdapter.Record] = [:]
        for id in 0...10_000 {
            nodes[id] = .init(text: id == AccessibilityTreeReader<FakeNodeAdapter>.maxDepth ? "last" : nil,
                              children: id == 10_000 ? [] : [id + 1])
        }
        let adapter = FakeNodeAdapter(nodes: nodes)
        let reader = AccessibilityTreeReader(adapter: adapter)

        let text = reader.visibleText(root: 0)

        #expect(text == "last")
        #expect(adapter.identityReads == AccessibilityTreeReader<FakeNodeAdapter>.maxDepth + 1)
    }

    @Test func hugeTextlessTreeStopsAtNodeBudget() {
        let children = Array(1...10_000)
        var nodes = Dictionary(uniqueKeysWithValues: children.map { ($0, FakeNodeAdapter.Record(text: nil, children: [])) })
        nodes[0] = .init(text: nil, children: children)
        let adapter = FakeNodeAdapter(nodes: nodes)
        let reader = AccessibilityTreeReader(adapter: adapter)

        #expect(reader.visibleText(root: 0).isEmpty)
        #expect(adapter.identityReads == AccessibilityTreeReader<FakeNodeAdapter>.maxNodes)
    }

    @Test func characterCapStopsFurtherNodeReads() {
        let adapter = FakeNodeAdapter(nodes: [
            1: .init(text: String(repeating: "x", count: AccessibilityTreeReader<FakeNodeAdapter>.maxCharacters), children: [2]),
            2: .init(text: "must not be read", children: [])
        ])
        let reader = AccessibilityTreeReader(adapter: adapter)

        let text = reader.visibleText(root: 1)

        #expect(text.count == AccessibilityTreeReader<FakeNodeAdapter>.maxCharacters)
        #expect(adapter.identityReads == 1)
        #expect(adapter.childrenReads == 0)
    }
}

@MainActor
private final class FakeAccessibilityContext: AccessibilityContextProviding {
    enum Call: Equatable { case identity, permission, selectedText, focusedField, activeWindow, windowMetadata }

    let trusted: Bool
    var identityValue: AccessibilityAppIdentity
    var identityAfterFirstRead: AccessibilityAppIdentity?
    let selectedTextValue: String?
    let focusedFieldValue: AccessibilityFocusedField?
    let activeWindowValue: AccessibilityWindow?
    var calls: [Call] = []
    var requestedPIDs: [pid_t] = []

    init(
        trusted: Bool = true,
        identity: AccessibilityAppIdentity = .init(appName: nil, bundleID: nil, pid: 0),
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

    func frontmostAppIdentity() -> AccessibilityAppIdentity {
        calls.append(.identity)
        defer { if let identityAfterFirstRead { identityValue = identityAfterFirstRead } }
        return identityValue
    }
    func isTrusted() -> Bool { calls.append(.permission); return trusted }
    func selectedText(pid: pid_t) -> String? { calls.append(.selectedText); requestedPIDs.append(pid); return selectedTextValue }
    func focusedField(pid: pid_t) -> AccessibilityFocusedField? { calls.append(.focusedField); requestedPIDs.append(pid); return focusedFieldValue }
    func activeWindow(pid: pid_t) -> AccessibilityWindow? { calls.append(.activeWindow); requestedPIDs.append(pid); return activeWindowValue }
    func activeWindowMetadata(pid: pid_t) -> AccessibilityWindowMetadata? {
        calls.append(.windowMetadata)
        requestedPIDs.append(pid)
        return activeWindowValue.map { .init(title: $0.title) }
    }
}

@MainActor
private final class FakeNodeAdapter: AccessibilityNodeAdapting {
    typealias Node = Int
    typealias Identity = Int
    struct Record { let text: String?; let children: [Int] }
    let nodes: [Int: Record]
    var identityReads = 0
    var childrenReads = 0

    init(nodes: [Int: Record]) { self.nodes = nodes }
    func identity(of node: Int) -> Int { identityReads += 1; return node }
    func isSecure(_ node: Int) -> Bool { false }
    func visibleText(of node: Int) -> String? { nodes[node]?.text }
    func children(of node: Int) -> [Int] { childrenReads += 1; return nodes[node]?.children ?? [] }
}
