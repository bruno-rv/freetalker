import Foundation
import Testing
@testable import FreeTalker

@MainActor
@Suite struct LocalContextProviderTests {
    @Test func offMakesNoAccessibilityCalls() {
        let adapter = FakeAccessibilityContext()
        let provider = AccessibilityLocalContextProvider(accessibility: adapter)

        let capture = provider.capture(scope: .off, target: .test)

        #expect(capture == .empty)
        #expect(adapter.calls.isEmpty)
    }

    @Test func selectedTextCapturesOnlyTheSelection() {
        let adapter = FakeAccessibilityContext(
            selectedText: "selected words",
            focusedField: .init(text: "entire draft", isSecure: false),
            activeWindow: .init(title: "Reply", visibleText: "whole window")
        )
        let provider = AccessibilityLocalContextProvider(accessibility: adapter)

        let capture = provider.capture(scope: .selectedText, target: .test)

        #expect(capture.context == .init(appName: "Mail", bundleID: "com.apple.mail", windowTitle: nil, text: "selected words"))
        #expect(adapter.calls == [.permission, .selectedText])
    }

    @Test func focusedFieldCapturesEditableValueCappedAtEightThousandCharacters() {
        let adapter = FakeAccessibilityContext(
            focusedField: .init(text: String(repeating: "a", count: 8_001), isSecure: false)
        )
        let provider = AccessibilityLocalContextProvider(accessibility: adapter)

        let capture = provider.capture(scope: .focusedField, target: .test)

        #expect(capture.context.text.count == 8_000)
        #expect(adapter.calls == [.permission, .focusedField])
    }

    @Test func secureFocusedFieldYieldsNoText() {
        let adapter = FakeAccessibilityContext(
            focusedField: .init(text: "secret", isSecure: true)
        )
        let provider = AccessibilityLocalContextProvider(accessibility: adapter)

        let capture = provider.capture(scope: .focusedField, target: .test)

        #expect(capture.context.text.isEmpty)
    }

    @Test func activeWindowCapturesWindowTitleAndVisibleTextCappedAtTwelveThousandCharacters() {
        let adapter = FakeAccessibilityContext(
            activeWindow: .init(title: "Editor", visibleText: String(repeating: "b", count: 12_001))
        )
        let provider = AccessibilityLocalContextProvider(accessibility: adapter)

        let capture = provider.capture(scope: .activeWindow, target: .test)

        #expect(capture.context.windowTitle == "Editor")
        #expect(capture.context.text.count == 12_000)
        #expect(adapter.calls == [.permission, .activeWindow])
    }

    @Test func windowOCRNeedsNoAccessibilityPermissionOrAXRead() {
        let adapter = FakeAccessibilityContext(
            trusted: false,
            activeWindow: .init(title: "Document", visibleText: "must not be read")
        )
        let provider = AccessibilityLocalContextProvider(accessibility: adapter)

        let target = ContextTargetSnapshot(appName: "Preview", bundleID: "com.apple.Preview", processID: 41, windowID: 77, windowTitle: nil)
        let capture = provider.capture(scope: .windowOCR, target: target)

        #expect(capture.context == .init(appName: "Preview", bundleID: "com.apple.Preview", windowTitle: nil, text: ""))
        #expect(capture.limitation == nil)
        #expect(adapter.calls.isEmpty)
    }

    @Test func missingPermissionReturnsAppIdentityAndTypedLimitationWithoutAXReads() {
        let adapter = FakeAccessibilityContext(
            trusted: false,
            selectedText: "must not be read"
        )
        let provider = AccessibilityLocalContextProvider(accessibility: adapter)

        let target = ContextTargetSnapshot(appName: "Mail", bundleID: "com.apple.mail", processID: 41, windowID: nil, windowTitle: nil)
        let capture = provider.capture(scope: .selectedText, target: target)

        #expect(capture.context == .init(appName: "Mail", bundleID: "com.apple.mail", windowTitle: nil, text: ""))
        #expect(capture.limitation == .accessibilityPermissionRequired)
        #expect(adapter.calls == [.permission])
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

    @Test func captureRootsAllAXReadsToPassedSnapshotPID() {
        let adapter = FakeAccessibilityContext(
            activeWindow: .init(title: "Original window", visibleText: "Original content")
        )
        let provider = AccessibilityLocalContextProvider(accessibility: adapter)

        let target = ContextTargetSnapshot(appName: "Original", bundleID: "original.app", processID: 41, windowID: 77, windowTitle: "Original window")
        let capture = provider.capture(scope: .activeWindow, target: target)

        #expect(capture.context.appName == "Original")
        #expect(capture.context.text == "Original content")
        #expect(adapter.requestedPIDs == [41])
    }
}

private extension ContextTargetSnapshot {
    static let test = ContextTargetSnapshot(appName: "Mail", bundleID: "com.apple.mail", processID: 41, windowID: 77, windowTitle: "Reply")
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

    @Test func wideLazyTreeMaterializesAndEnqueuesOnlyRemainingNodeBudget() {
        let adapter = FakeNodeAdapter(nodes: [
            0: .init(text: nil, children: [], lazyChildCount: 1_000_000)
        ])
        let reader = AccessibilityTreeReader(adapter: adapter)

        #expect(reader.visibleText(root: 0).isEmpty)
        #expect(adapter.childLimits == [AccessibilityTreeReader<FakeNodeAdapter>.maxNodes - 1])
        #expect(adapter.totalChildrenReturned == AccessibilityTreeReader<FakeNodeAdapter>.maxNodes - 1)
        #expect(adapter.largestChildrenReply <= AccessibilityTreeReader<FakeNodeAdapter>.maxNodes - 1)
    }
}

@MainActor
private final class FakeAccessibilityContext: AccessibilityContextProviding {
    enum Call: Equatable { case permission, selectedText, focusedField, activeWindow, windowMetadata }

    let trusted: Bool
    let selectedTextValue: String?
    let focusedFieldValue: AccessibilityFocusedField?
    let activeWindowValue: AccessibilityWindow?
    var calls: [Call] = []
    var requestedPIDs: [pid_t] = []

    init(
        trusted: Bool = true,
        selectedText: String? = nil,
        focusedField: AccessibilityFocusedField? = nil,
        activeWindow: AccessibilityWindow? = nil
    ) {
        self.trusted = trusted
        selectedTextValue = selectedText
        focusedFieldValue = focusedField
        activeWindowValue = activeWindow
    }

    func isTrusted() -> Bool { calls.append(.permission); return trusted }
    func selectedText(pid: pid_t) -> String? { calls.append(.selectedText); requestedPIDs.append(pid); return selectedTextValue }
    func focusedField(pid: pid_t) -> AccessibilityFocusedField? { calls.append(.focusedField); requestedPIDs.append(pid); return focusedFieldValue }
    func activeWindow(pid: pid_t) -> AccessibilityWindow? { calls.append(.activeWindow); requestedPIDs.append(pid); return activeWindowValue }
    func focusedWindowMetadata(pid: pid_t) -> AccessibilityWindowMetadata? {
        calls.append(.windowMetadata)
        requestedPIDs.append(pid)
        return activeWindowValue.map { .init(title: $0.title) }
    }
}

@MainActor
private final class FakeNodeAdapter: AccessibilityNodeAdapting {
    typealias Node = Int
    typealias Identity = Int
    struct Record {
        let text: String?
        let children: [Int]
        let lazyChildCount: Int

        init(text: String?, children: [Int], lazyChildCount: Int = 0) {
            self.text = text
            self.children = children
            self.lazyChildCount = lazyChildCount
        }
    }
    let nodes: [Int: Record]
    var identityReads = 0
    var childrenReads = 0
    var childLimits: [Int] = []
    var totalChildrenReturned = 0
    var largestChildrenReply = 0

    init(nodes: [Int: Record]) { self.nodes = nodes }
    func identity(of node: Int) -> Int { identityReads += 1; return node }
    func isSecure(_ node: Int) -> Bool { false }
    func visibleText(of node: Int) -> String? { nodes[node]?.text }
    func children(of node: Int, maxCount: Int) -> [Int] {
        childrenReads += 1
        childLimits.append(maxCount)
        guard let record = nodes[node] else { return [] }
        let children = record.lazyChildCount > 0
            ? Array(1...min(record.lazyChildCount, maxCount))
            : Array(record.children.prefix(maxCount))
        totalChildrenReturned += children.count
        largestChildrenReply = max(largestChildrenReply, children.count)
        return children
    }
}
