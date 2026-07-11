import CoreGraphics
import ApplicationServices
import Foundation
import Testing
@testable import FreeTalker

@MainActor
@Suite struct VoiceEditTargetTests {
    @Test func selectionFingerprintChangesWithSelectedText() {
        let first = SelectionSnapshot.fingerprint(for: "hello")
        #expect(first == SelectionSnapshot.fingerprint(for: "hello"))
        #expect(first != SelectionSnapshot.fingerprint(for: "hello!"))
    }

    @Test func secureAndProtectedFieldsAreRejected() {
        #expect(SystemAccessibilityNodeAdapter.isSecure(role: "AXSecureTextField", protected: false))
        #expect(SystemAccessibilityNodeAdapter.isSecure(role: "AXTextArea", protected: true))
        #expect(!SystemAccessibilityNodeAdapter.isSecure(role: "AXTextArea", protected: false))
    }

    @Test func staleSelectionCannotBeReplaced() {
        let expected = SelectionSnapshot.fingerprint(for: "selected")
        #expect(SelectionAccess.revalidationError(
            appMatches: true,
            elementMatches: true,
            windowMatches: true,
            expectedRange: NSRange(location: 3, length: 8),
            currentRange: NSRange(location: 3, length: 8),
            expectedFingerprint: expected,
            currentText: "changed!"
        ) == .selectionChanged)
        #expect(SelectionAccess.revalidationError(
            appMatches: true,
            elementMatches: true,
            windowMatches: true,
            expectedRange: NSRange(location: 3, length: 8),
            currentRange: NSRange(location: 4, length: 8),
            expectedFingerprint: expected,
            currentText: "selected"
        ) == .selectionChanged)
    }

    @Test func voiceEditHotkeyDispatchIsSynchronousAndSwallowed() {
        let ptt = HotKeyMatcher(spec: .default)
        let redo = HotKeyMatcher(spec: HotKeySpec(modifiers: 0, keyCode: 105))
        let voice = HotKeyMatcher(spec: HotKeySpec(modifiers: 0, keyCode: 107))
        var mutablePTT = ptt
        var mutableRedo: HotKeyMatcher? = redo
        var mutableVoice: HotKeyMatcher? = voice

        let down = HotKeyManager.dispatch(
            kind: .keyDown, keyCode: 107, flags: 0, isAutorepeat: false,
            matcher: &mutablePTT, redoMatcher: &mutableRedo, voiceEditMatcher: &mutableVoice
        )
        #expect(down.voiceEditEngaged)
        #expect(down.swallow)

        let up = HotKeyManager.dispatch(
            kind: .keyUp, keyCode: 107, flags: 0, isAutorepeat: false,
            matcher: &mutablePTT, redoMatcher: &mutableRedo, voiceEditMatcher: &mutableVoice
        )
        #expect(!up.voiceEditEngaged)
        #expect(up.swallow)
    }

    @Test func voiceEditActionRunsBeforeEventTapReturns() {
        var called = false
        let outcome = HotKeyManager.DispatchOutcome(voiceEditEngaged: true, swallow: true)
        HotKeyManager.deliverVoiceEditIfNeeded(outcome: outcome, eventSeconds: 42) { seconds in
            #expect(seconds == 42)
            called = true
        }
        #expect(called)
    }

    @Test func productionVoiceEditWiringCapturesPendingSelection() throws {
        let manager = HotKeyManager()
        let access = StubSelectionAccess(result: .success(Self.snapshot(text: "draft")))
        var pending: SelectionSnapshot?
        var messages: [String] = []
        AppCoordinator.configureVoiceEditHotKey(manager: manager) {
            AppCoordinator.handleVoiceEditHotKey(
                selectionAccess: access,
                pendingSelection: &pending,
                flash: { messages.append($0) }
            )
        }

        manager.onVoiceEditKeyDown?(1)

        #expect(pending?.text == "draft")
        #expect(messages.isEmpty)
    }

    @Test(arguments: [
        (SelectionAccessError.noEditableSelection, "Select editable text first"),
        (.secureField, "Voice Edit is unavailable in secure fields")
    ])
    func productionVoiceEditWiringSurfacesTypedCaptureErrors(_ error: SelectionAccessError, _ message: String) {
        let access = StubSelectionAccess(result: .failure(error))
        var pending: SelectionSnapshot?
        var messages: [String] = []

        AppCoordinator.handleVoiceEditHotKey(
            selectionAccess: access,
            pendingSelection: &pending,
            flash: { messages.append($0) }
        )

        #expect(pending == nil)
        #expect(messages == [message])
    }

    @Test func captureRejectsDriftAtEveryRangeAndTextReadBoundary() {
        for changedRead in 0..<4 {
            let adapter = ScriptedSelectionAdapter(reads: Self.driftingReads(changedRead: changedRead))
            let access = Self.access(adapter: adapter)
            #expect(throws: SelectionAccessError.selectionChanged) { try access.capture() }
            #expect(adapter.replacements.isEmpty)
        }
    }

    @Test func captureRejectsElementOrWindowIdentityDrift() {
        for driftWindow in [false, true] {
            let adapter = ScriptedSelectionAdapter(reads: Self.stableReads)
            let changed = driftWindow
                ? Self.target(window: AXUIElementCreateApplication(99))
                : Self.target(element: AXUIElementCreateApplication(99))
            let access = Self.access(adapter: adapter, targets: [Self.target(), changed])
            #expect(throws: SelectionAccessError.targetChanged) { try access.capture() }
            #expect(adapter.replacements.isEmpty)
        }
    }

    @Test func replaceRejectsDriftAtEveryReadBoundaryWithoutSettingText() throws {
        for changedRead in 0..<8 {
            var reads = Self.stableReads + Self.stableReads
            reads[changedRead] = changedRead.isMultiple(of: 2)
                ? .range(NSRange(location: 0, length: 4))
                : .text("drift")
            let adapter = ScriptedSelectionAdapter(reads: reads)
            let access = Self.access(adapter: adapter, targetCount: 4)
            let snapshot = Self.snapshot(text: "draft")

            #expect(throws: SelectionAccessError.selectionChanged) {
                try access.replace(snapshot, with: "replacement")
            }
            #expect(adapter.replacements.isEmpty)
            #expect(adapter.rangesSet.isEmpty)
        }
    }

    @Test func replacePerformsOneWriteOnlyAfterFinalRevalidation() throws {
        let adapter = ScriptedSelectionAdapter(reads: Self.stableReads + Self.stableReads)
        let access = Self.access(adapter: adapter, targetCount: 4)

        try access.replace(Self.snapshot(text: "draft"), with: "replacement")

        #expect(adapter.rangesSet.isEmpty)
        #expect(adapter.replacements == ["replacement"])
    }

    @Test func replaceRejectsIdentityDriftAtEveryTargetReadBoundaryWithoutSettingText() {
        for driftWindow in [false, true] {
            for changedRead in 0..<4 {
                var targets = Array(repeating: Self.target(), count: 4)
                let changedIdentity = AXUIElementCreateApplication(pid_t(100 + changedRead))
                targets[changedRead] = driftWindow
                    ? Self.target(window: changedIdentity)
                    : Self.target(element: changedIdentity)
                let adapter = ScriptedSelectionAdapter(reads: Self.stableReads + Self.stableReads)
                let access = Self.access(adapter: adapter, targets: targets)

                #expect(throws: SelectionAccessError.targetChanged) {
                    try access.replace(Self.snapshot(text: "draft"), with: "replacement")
                }
                #expect(adapter.replacements.isEmpty)
                #expect(adapter.rangesSet.isEmpty)
            }
        }
    }

    @Test func stopStartPreservesSwallowedKeyUpExactlyOnce() {
        var ptt = HotKeyMatcher(spec: .default)
        var redo: HotKeyMatcher? = HotKeyMatcher(spec: HotKeySpec(modifiers: 0, keyCode: 105))
        var voice: HotKeyMatcher? = HotKeyMatcher(spec: HotKeySpec(modifiers: 0, keyCode: 107))
        _ = voice?.handle(.keyDown, keyCode: 107, flags: 0)
        var tombstones = HotKeyManager.captureSwallowedKeyUpTombstones(
            matcher: ptt, redoMatcher: redo, voiceEditMatcher: voice
        )

        HotKeyManager.resetMatchers(matcher: &ptt, redoMatcher: &redo, voiceEditMatcher: &voice)

        #expect(HotKeyManager.handleSwallowedKeyUpTombstone(
            kind: .keyUp, keyCode: 105, isAutorepeat: false, tombstones: &tombstones
        ) == .dispatch)
        #expect(HotKeyManager.handleSwallowedKeyUpTombstone(
            kind: .keyUp, keyCode: 107, isAutorepeat: false, tombstones: &tombstones
        ) == .swallowWithoutDispatch)
        #expect(HotKeyManager.handleSwallowedKeyUpTombstone(
            kind: .keyUp, keyCode: 107, isAutorepeat: false, tombstones: &tombstones
        ) == .dispatch)
        #expect(voice?.handle(.keyUp, keyCode: 107, flags: 0).released == false)
    }

    @Test func swallowedKeyUpTombstonesStayBoundedAcrossRestarts() {
        var tombstones = Set<UInt16>()
        for keyCode in UInt16(1)...UInt16(20) {
            HotKeyManager.mergeSwallowedKeyUpTombstones([keyCode], into: &tombstones)
        }
        #expect(tombstones.count <= HotKeyManager.maximumSwallowedKeyUpTombstones)
    }

    @Test func autorepeatDownRetainsRestartTombstoneUntilMatchingKeyUp() {
        var tombstones: Set<UInt16> = [107]

        let repeatOne = HotKeyManager.handleSwallowedKeyUpTombstone(
            kind: .keyDown, keyCode: 107, isAutorepeat: true, tombstones: &tombstones
        )
        let repeatTwo = HotKeyManager.handleSwallowedKeyUpTombstone(
            kind: .keyDown, keyCode: 107, isAutorepeat: true, tombstones: &tombstones
        )
        #expect(repeatOne == .swallowWithoutDispatch)
        #expect(repeatTwo == .swallowWithoutDispatch)
        #expect(tombstones == [107])

        let keyUp = HotKeyManager.handleSwallowedKeyUpTombstone(
            kind: .keyUp, keyCode: 107, isAutorepeat: false, tombstones: &tombstones
        )
        #expect(keyUp == .swallowWithoutDispatch)
        #expect(tombstones.isEmpty)
        #expect(HotKeyManager.handleSwallowedKeyUpTombstone(
            kind: .keyUp, keyCode: 107, isAutorepeat: false, tombstones: &tombstones
        ) == .dispatch)
    }

    @Test func nonrepeatDownRetiresRestartTombstoneAndDispatchesNewCycle() {
        var tombstones: Set<UInt16> = [107]
        #expect(HotKeyManager.handleSwallowedKeyUpTombstone(
            kind: .keyDown, keyCode: 107, isAutorepeat: false, tombstones: &tombstones
        ) == .dispatch)
        #expect(tombstones.isEmpty)
    }

    @Test func eventTapMainThreadContractIsExplicit() {
        #expect(HotKeyManager.eventTapThreadIsValid())
    }

    @Test func threeHotkeysRejectEveryCollision() {
        let ptt = HotKeySpec.default
        let redo = HotKeySpec(modifiers: 0, keyCode: 105)
        let voice = HotKeySpec(modifiers: 0, keyCode: 107)
        #expect(HotKeySpec.validActionSpec(voice, pttSpec: ptt, otherActionSpec: redo) == voice)
        #expect(HotKeySpec.validActionSpec(redo, pttSpec: ptt, otherActionSpec: redo) == nil)
        #expect(HotKeySpec.validActionSpec(ptt, pttSpec: ptt, otherActionSpec: redo) == nil)
    }

    @Test func voiceEditHotkeyPersistsAndInvalidAssignmentsAreDropped() {
        let suite = "VoiceEditTargetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let voice = HotKeySpec(modifiers: 0, keyCode: 107)

        var settings: AppSettings? = AppSettings(defaults: defaults)
        settings?.voiceEditHotKeySpec = voice
        settings = AppSettings(defaults: defaults)
        #expect(settings?.voiceEditHotKeySpec == voice)

        settings?.redoHotKeySpec = voice
        #expect(settings?.redoHotKeySpec == nil)
        #expect(settings?.voiceEditHotKeySpec == voice)
    }

    private static let stableReads: [ScriptedSelectionAdapter.Read] = [
        .range(NSRange(location: 0, length: 5)), .text("draft"),
        .range(NSRange(location: 0, length: 5)), .text("draft")
    ]

    private static func driftingReads(changedRead: Int) -> [ScriptedSelectionAdapter.Read] {
        var reads = stableReads
        reads[changedRead] = changedRead.isMultiple(of: 2)
            ? .range(NSRange(location: 1, length: 5))
            : .text("drift")
        return reads
    }

    private static let element = AXUIElementCreateSystemWide()
    private static let window = AXUIElementCreateSystemWide()

    private static func target(element: AXUIElement = element, window: AXUIElement = window) -> InsertionTarget {
        InsertionTarget(bundleID: "test.app", pid: 7, focusedElement: element, window: window)
    }

    private static func snapshot(text: String) -> SelectionSnapshot {
        SelectionSnapshot(
            target: target(), range: NSRange(location: 0, length: text.utf16.count),
            text: text, fingerprint: SelectionSnapshot.fingerprint(for: text)
        )
    }

    private static func access(
        adapter: ScriptedSelectionAdapter,
        targets: [InsertionTarget]? = nil,
        targetCount: Int = 2
    ) -> SelectionAccess {
        var queue = targets ?? Array(repeating: target(), count: targetCount)
        return SelectionAccess(adapter: adapter, targetProvider: { queue.removeFirst() })
    }
}

@MainActor
private final class StubSelectionAccess: SelectionAccessing {
    let result: Result<SelectionSnapshot, Error>
    init(result: Result<SelectionSnapshot, Error>) { self.result = result }
    func capture() throws -> SelectionSnapshot { try result.get() }
    func replace(_ snapshot: SelectionSnapshot, with text: String) throws {}
}

@MainActor
private final class ScriptedSelectionAdapter: SelectionAccessibilityAdapting {
    enum Read {
        case range(NSRange)
        case text(String)
    }

    var reads: [Read]
    var rangesSet: [NSRange] = []
    var replacements: [String] = []
    init(reads: [Read]) { self.reads = reads }
    func isSecure(_ element: AXUIElement) -> Bool { false }
    func isEditable(_ element: AXUIElement) -> Bool { true }
    func elementsEqual(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return CFEqual(lhs, rhs)
    }
    func selectedTextRange(of element: AXUIElement) -> NSRange? {
        guard case let .range(value) = reads.removeFirst() else { Issue.record("Expected range read"); return nil }
        return value
    }
    func selectedText(of element: AXUIElement) -> String? {
        guard case let .text(value) = reads.removeFirst() else { Issue.record("Expected text read"); return nil }
        return value
    }
    func setSelectedTextRange(of element: AXUIElement, to range: NSRange) -> Bool {
        rangesSet.append(range)
        return true
    }
    func replaceSelectedText(of element: AXUIElement, with text: String) -> Bool {
        replacements.append(text)
        return true
    }
}
