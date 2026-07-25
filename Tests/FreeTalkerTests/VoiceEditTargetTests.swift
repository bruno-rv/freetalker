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

    /// Codex Round 2 finding 2: `revalidationError`'s new `documentMatches` parameter fails closed
    /// to `.targetChanged` on its own — independent of app/element/window/range/text all still
    /// agreeing — and its default (`true`) preserves every pre-fix call site that never captured a
    /// document discriminator at all.
    @Test func revalidationErrorTreatsADocumentMismatchAsTargetChanged() {
        let fingerprint = SelectionSnapshot.fingerprint(for: "selected")
        #expect(SelectionAccess.revalidationError(
            appMatches: true, elementMatches: true, windowMatches: true, documentMatches: false,
            expectedRange: NSRange(location: 3, length: 8), currentRange: NSRange(location: 3, length: 8),
            expectedFingerprint: fingerprint, currentText: "selected"
        ) == .targetChanged)
        #expect(SelectionAccess.revalidationError(
            appMatches: true, elementMatches: true, windowMatches: true,
            expectedRange: NSRange(location: 3, length: 8), currentRange: NSRange(location: 3, length: 8),
            expectedFingerprint: fingerprint, currentText: "selected"
        ) == nil)
    }

    @Test func voiceEditHotkeyDispatchIsSynchronousAndSwallowed() {
        let ptt = HotKeyMatcher(spec: .default)
        let insertLastDictation = HotKeyMatcher(spec: HotKeySpec(modifiers: 0, keyCode: 105))
        let voice = HotKeyMatcher(spec: HotKeySpec(modifiers: 0, keyCode: 107))
        var mutablePTT = ptt
        var mutableInsertLastDictation: HotKeyMatcher? = insertLastDictation
        var mutableVoice: HotKeyMatcher? = voice
        var mutableHistoryPanel: HotKeyMatcher?
        var mutableCorrectionPanel: HotKeyMatcher?

        let down = HotKeyManager.dispatch(
            kind: .keyDown, keyCode: 107, flags: 0, isAutorepeat: false,
            matcher: &mutablePTT, insertLastDictationMatcher: &mutableInsertLastDictation, voiceEditMatcher: &mutableVoice, historyPanelMatcher: &mutableHistoryPanel, correctionPanelMatcher: &mutableCorrectionPanel
        )
        #expect(down.voiceEditEngaged)
        #expect(down.swallow)

        let up = HotKeyManager.dispatch(
            kind: .keyUp, keyCode: 107, flags: 0, isAutorepeat: false,
            matcher: &mutablePTT, insertLastDictationMatcher: &mutableInsertLastDictation, voiceEditMatcher: &mutableVoice, historyPanelMatcher: &mutableHistoryPanel, correctionPanelMatcher: &mutableCorrectionPanel
        )
        #expect(!up.voiceEditEngaged)
        #expect(up.swallow)
    }

    @Test func historyPanelHotkeyDispatchIsSynchronousAndSwallowed() {
        var mutablePTT = HotKeyMatcher(spec: .default)
        var mutableInsertLastDictation: HotKeyMatcher? = HotKeyMatcher(spec: HotKeySpec(modifiers: 0, keyCode: 105))
        var mutableVoice: HotKeyMatcher? = HotKeyMatcher(spec: HotKeySpec(modifiers: 0, keyCode: 107))
        var mutableHistoryPanel: HotKeyMatcher? = HotKeyMatcher(spec: HotKeySpec(modifiers: 0, keyCode: 4))
        var mutableCorrectionPanel: HotKeyMatcher?

        let down = HotKeyManager.dispatch(
            kind: .keyDown, keyCode: 4, flags: 0, isAutorepeat: false,
            matcher: &mutablePTT, insertLastDictationMatcher: &mutableInsertLastDictation, voiceEditMatcher: &mutableVoice, historyPanelMatcher: &mutableHistoryPanel, correctionPanelMatcher: &mutableCorrectionPanel
        )
        #expect(down.historyPanelEngaged)
        #expect(down.swallow)
        #expect(!down.voiceEditEngaged)
        #expect(!down.insertLastDictationEngaged)

        let up = HotKeyManager.dispatch(
            kind: .keyUp, keyCode: 4, flags: 0, isAutorepeat: false,
            matcher: &mutablePTT, insertLastDictationMatcher: &mutableInsertLastDictation, voiceEditMatcher: &mutableVoice, historyPanelMatcher: &mutableHistoryPanel, correctionPanelMatcher: &mutableCorrectionPanel
        )
        #expect(!up.historyPanelEngaged)
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

    @Test func captureOwnershipRejectsPTTAndVoiceEditOverlapInBothDirections() {
        #expect(AppCoordinator.captureStartDecision(current: .none, requested: .dictation) == .start)
        #expect(AppCoordinator.captureStartDecision(current: .dictation, requested: .voiceEdit) == .busy(.dictation))
        #expect(AppCoordinator.captureStartDecision(current: .voiceEdit, requested: .dictation) == .busy(.voiceEdit))
    }

    @Test func repeatedCapturePressStopsOnlyItsCurrentOwner() {
        #expect(AppCoordinator.capturePressDecision(current: .voiceEdit, pressed: .voiceEdit) == .stop)
        #expect(AppCoordinator.capturePressDecision(current: .dictation, pressed: .voiceEdit) == .busy(.dictation))
        #expect(AppCoordinator.capturePressDecision(current: .voiceEdit, pressed: .dictation) == .busy(.voiceEdit))
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

        // `recentInsertionSelection: { nil }` — deterministic regardless of
        // `RecentInsertionStore.shared`'s process-wide state; the fallback itself is covered by
        // `voiceEditFallsBackToRecentInsertionOnlyForNoEditableSelection` below.
        AppCoordinator.handleVoiceEditHotKey(
            selectionAccess: access,
            pendingSelection: &pending,
            recentInsertionSelection: { nil },
            flash: { messages.append($0) }
        )

        #expect(pending == nil)
        #expect(messages == [message])
    }

    /// Correction Loop signal B (BRAINSTORM_CORRECTION_LOOP.md): the fallback is consulted ONLY
    /// on `.noEditableSelection` — never on `.secureField` (would bypass a security check) or
    /// `.targetChanged`/`.selectionChanged` (the live capture just proved this isn't the right
    /// target). A `.noEditableSelection` with a fallback available uses it instead of flashing.
    @Test func voiceEditFallsBackToRecentInsertionOnlyForNoEditableSelection() {
        let fallback = Self.snapshot(text: "the recent dictation")
        let calls = CallCounter()

        var pending: SelectionSnapshot?
        var messages: [String] = []
        AppCoordinator.handleVoiceEditHotKey(
            selectionAccess: StubSelectionAccess(result: .failure(SelectionAccessError.noEditableSelection)),
            pendingSelection: &pending,
            recentInsertionSelection: { calls.increment(); return fallback },
            flash: { messages.append($0) }
        )
        #expect(pending?.text == "the recent dictation")
        #expect(messages.isEmpty)
        #expect(calls.count == 1)

        for error in [SelectionAccessError.secureField, .targetChanged, .selectionChanged, .noFrontmostApplication, .replacementFailed] {
            pending = nil
            messages = []
            calls.reset()
            AppCoordinator.handleVoiceEditHotKey(
                selectionAccess: StubSelectionAccess(result: .failure(error)),
                pendingSelection: &pending,
                recentInsertionSelection: { calls.increment(); return fallback },
                flash: { messages.append($0) }
            )
            #expect(pending == nil)
            #expect(calls.count == 0, "fallback must not be consulted for \(error)")
        }
    }

    /// A `.noEditableSelection` with NO fallback available (nothing recent, or it's drifted)
    /// falls through to the ordinary "select text first" message exactly as before this feature.
    @Test func voiceEditNoEditableSelectionWithNoFallbackFlashesTheOrdinaryMessage() {
        var pending: SelectionSnapshot?
        var messages: [String] = []
        AppCoordinator.handleVoiceEditHotKey(
            selectionAccess: StubSelectionAccess(result: .failure(SelectionAccessError.noEditableSelection)),
            pendingSelection: &pending,
            recentInsertionSelection: { nil },
            flash: { messages.append($0) }
        )
        #expect(pending == nil)
        #expect(messages == ["Select editable text first"])
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

    /// Round 3 fix, STEP 2: the document discriminator is checked ONLY for Correction Loop signal
    /// B's fallback (`SelectionSnapshot.correctionDictationID != nil` — set exclusively by
    /// `CorrectionTargeting.selectRecentInsertion`). For that fallback, a genuine (non-URL)
    /// per-document token that CHANGED between snapshot and replace must still refuse — the
    /// remembered dictation lived in document A; the user switched to a DIFFERENT document
    /// reusing the same recycled AX element/window with IDENTICAL text at the same range
    /// (document B) before Replace runs — element/window/range/text all still match, but it's the
    /// wrong document.
    @Test func replaceRejectsAChangedDocumentForACorrectionFallbackSnapshot() {
        let adapter = ScriptedSelectionAdapter(reads: Self.stableReads + Self.stableReads)
        // Every live read (before/after, both passes) reports the SAME reused element/window but
        // a document discriminator that differs from what the snapshot remembered.
        let access = Self.access(adapter: adapter, targets: Array(repeating: Self.target(document: "doc-B"), count: 4))
        let snapshot = Self.snapshot(text: "draft", document: "doc-A", correctionDictationID: 1)

        #expect(throws: SelectionAccessError.targetChanged) {
            try access.replace(snapshot, with: "replacement")
        }
        #expect(adapter.replacements.isEmpty)
        #expect(adapter.rangesSet.isEmpty)
    }

    /// Round 3 fix, STEP 2's core regression test: ordinary MANUAL Voice Edit (`correctionDictationID
    /// == nil`) must behave exactly as `main` — a changed `kAXDocumentAttribute` value (e.g. an
    /// SPA rewriting its URL mid-instruction via `history.replaceState`, with no actual target
    /// change at all — Round 3 finding 4) must NOT be treated as `.targetChanged` when this
    /// snapshot was never produced by the correction fallback.
    @Test func replaceIgnoresAChangedDocumentForAnOrdinaryManualVoiceEditSnapshot() throws {
        let adapter = ScriptedSelectionAdapter(reads: Self.stableReads + Self.stableReads)
        let access = Self.access(adapter: adapter, targets: Array(repeating: Self.target(document: "doc-B"), count: 4))
        let snapshot = Self.snapshot(text: "draft", document: "doc-A") // correctionDictationID: nil

        try access.replace(snapshot, with: "replacement")

        #expect(adapter.replacements == ["replacement"])
    }

    /// Round 3 fix, STEP 3 (finding 2): a URL-SHAPED discriminator never proves document identity
    /// on its own — a duplicated tab shares the exact same URL as its original. For the
    /// correction-fallback path, this must fail closed even when the URL still MATCHES — matching
    /// is exactly the ambiguous case finding 2 identified (a duplicate tab satisfies it too), and
    /// refusing is the correct, deliberately conservative outcome.
    ///
    /// Codex regression fix: `isURLShaped` previously only recognised `://`, so non-hierarchical
    /// Chromium document URLs — `data:`, `about:`, `file:`, `mailto:` — were misclassified as
    /// NON-URL and trusted as stable discriminators, letting a recycled AX element/window with a
    /// matching `data:`/`about:` value pass this gate for the WRONG duplicated tab. Covering every
    /// valid URI scheme (via `URLComponents(string:)?.scheme`) closes that hole.
    @Test func replaceRejectsACorrectionFallbackWhenTheDocumentDiscriminatorIsURLShapedEvenOnAMatch() {
        for url in [
            "https://mail.example.com/mail/u/0/#inbox",
            "data:text/html,<p>hi</p>",
            "about:blank",
            "file:///Users/x/doc.html",
            "mailto:a@b.com",
        ] {
            let adapter = ScriptedSelectionAdapter(reads: Self.stableReads + Self.stableReads)
            let access = Self.access(adapter: adapter, targets: Array(repeating: Self.target(document: url), count: 4))
            let snapshot = Self.snapshot(text: "draft", document: url, correctionDictationID: 1)

            #expect(throws: SelectionAccessError.targetChanged) {
                try access.replace(snapshot, with: "replacement")
            }
            #expect(adapter.replacements.isEmpty)
        }
    }

    /// A non-URL discriminator that still matches is trusted for the correction-fallback path —
    /// Step 3 only refuses URL-shaped tokens, not every discriminator.
    @Test func replaceSucceedsForACorrectionFallbackSnapshotWhenANonURLDocumentDiscriminatorMatches() throws {
        let adapter = ScriptedSelectionAdapter(reads: Self.stableReads + Self.stableReads)
        let access = Self.access(adapter: adapter, targets: Array(repeating: Self.target(document: "doc-A"), count: 4))
        let snapshot = Self.snapshot(text: "draft", document: "doc-A", correctionDictationID: 1)

        try access.replace(snapshot, with: "replacement")

        #expect(adapter.replacements == ["replacement"])
    }

    /// A snapshot that never captured a document discriminator (an app that doesn't expose
    /// `kAXDocumentAttribute` at all) stays permissive even on the correction-fallback path —
    /// element/window identity alone still governs.
    @Test func replaceStillSucceedsWhenNeitherSnapshotNorLiveTargetHaveADocumentDiscriminator() throws {
        let adapter = ScriptedSelectionAdapter(reads: Self.stableReads + Self.stableReads)
        let access = Self.access(adapter: adapter, targetCount: 4)

        try access.replace(Self.snapshot(text: "draft", correctionDictationID: 1), with: "replacement")

        #expect(adapter.replacements == ["replacement"])
    }

    @Test func stopStartPreservesSwallowedKeyUpExactlyOnce() {
        var ptt = HotKeyMatcher(spec: .default)
        var insertLastDictation: HotKeyMatcher? = HotKeyMatcher(spec: HotKeySpec(modifiers: 0, keyCode: 105))
        var voice: HotKeyMatcher? = HotKeyMatcher(spec: HotKeySpec(modifiers: 0, keyCode: 107))
        var historyPanel: HotKeyMatcher?
        var correctionPanel: HotKeyMatcher?
        _ = voice?.handle(.keyDown, keyCode: 107, flags: 0)
        var tombstones = HotKeyManager.captureSwallowedKeyUpTombstones(
            matcher: ptt, insertLastDictationMatcher: insertLastDictation, voiceEditMatcher: voice, historyPanelMatcher: historyPanel, correctionPanelMatcher: correctionPanel
        )

        HotKeyManager.resetMatchers(matcher: &ptt, insertLastDictationMatcher: &insertLastDictation, voiceEditMatcher: &voice, historyPanelMatcher: &historyPanel, correctionPanelMatcher: &correctionPanel)

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

    @Test func fourHotkeysRejectEveryCollision() {
        let ptt = HotKeySpec.default
        let insertLastDictation = HotKeySpec(modifiers: 0, keyCode: 105)
        let voice = HotKeySpec(modifiers: 0, keyCode: 107)
        let historyPanel = HotKeySpec(modifiers: 0, keyCode: 4)
        // A candidate that collides with neither PTT nor either already-bound sibling is valid.
        #expect(HotKeySpec.validActionSpec(voice, pttSpec: ptt, otherActionSpecs: [insertLastDictation, historyPanel]) == voice)
        // Colliding with itself-as-a-sibling (re-binding the same chord to another slot) is rejected.
        #expect(HotKeySpec.validActionSpec(insertLastDictation, pttSpec: ptt, otherActionSpecs: [insertLastDictation, historyPanel]) == nil)
        // Colliding with a THIRD sibling (not just the first) is rejected too.
        #expect(HotKeySpec.validActionSpec(historyPanel, pttSpec: ptt, otherActionSpecs: [insertLastDictation, historyPanel]) == nil)
        // Colliding with PTT itself is rejected regardless of siblings.
        #expect(HotKeySpec.validActionSpec(ptt, pttSpec: ptt, otherActionSpecs: [insertLastDictation]) == nil)
        // A modifier-only candidate (no key) is never a valid action spec.
        #expect(HotKeySpec.validActionSpec(HotKeySpec(modifiers: 0x40, keyCode: nil), pttSpec: ptt, otherActionSpecs: []) == nil)
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

        settings?.insertLastDictationHotKeySpec = voice
        #expect(settings?.insertLastDictationHotKeySpec == nil)
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

    private static func target(element: AXUIElement = element, window: AXUIElement = window, document: String? = nil) -> InsertionTarget {
        InsertionTarget(bundleID: "test.app", pid: 7, focusedElement: element, window: window, document: document)
    }

    private static func snapshot(text: String, document: String? = nil, correctionDictationID: Int64? = nil) -> SelectionSnapshot {
        SelectionSnapshot(
            target: target(document: document), range: NSRange(location: 0, length: text.utf16.count),
            text: text, fingerprint: SelectionSnapshot.fingerprint(for: text),
            correctionDictationID: correctionDictationID
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

/// Mutable call counter for a `@MainActor @Sendable` closure — a plain captured `var` is
/// non-Sendable and fails the `recentInsertionSelection` closure's type check.
@MainActor
private final class CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
    func reset() { count = 0 }
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
