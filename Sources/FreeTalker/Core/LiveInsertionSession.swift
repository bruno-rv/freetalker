import AppKit
import CoreGraphics
import Foundation

/// Owns a grapheme-cluster ledger of everything typed into the target app during a live-streaming
/// Recording (BRAINSTORM_STREAMING_ASR.md). Types confirmed partials with
/// `CGEvent.keyboardSetUnicodeString` — not the pasteboard, so it never fights the save/restore
/// timer `Insertion.insert` uses (`Insertion.swift:144`) and doesn't thrash the clipboard dozens
/// of times per Recording.
@MainActor
final class LiveInsertionSession {
    enum FinalizeAction {
        case done
        case raw
        case cancel
    }

    enum Outcome: Equatable {
        /// The ledger was backspaced away; the caller should insert `text` (e.g. via
        /// `Insertion.insert`).
        case insert(String)
        /// The ledger was left on screen as-is (focus drift, an unverified readback, or over the
        /// replace cap) — the caller should place `text` on the clipboard and surface a HUD
        /// hint. Never backspaced.
        case clipboardOnly(String)
        /// The ledger was backspaced away (or was already empty) and there is nothing further to
        /// insert — Cancel, or Done/Raw with empty output.
        case none
    }

    // ponytail: 400-char replace cap, raise if backspace batching proves fast
    nonisolated static let replaceCap = 400

    // ponytail: the ledger lives only in memory — if the app crashes mid-Recording, already-typed
    // partials stay in the user's document with no ledger to reconcile them against on relaunch.
    // Deliberately NOT persisted and NEVER auto-backspaced after a crash: reconciling a
    // possibly-stale on-disk ledger against whatever the document looks like after restart is far
    // more dangerous than leaving the (correct, at-the-time) partial text as-is. See
    // DEFERRED-FINDINGS.md.
    private(set) var ledger: [Character] = []
    private(set) var isFrozen = false
    let target: InsertionTarget
    /// The capture generation (`AppCoordinator.recordingGeneration`) that created this session
    /// (Codex finding 7): a session may only ever be finalized by the capture that created it —
    /// see `AppCoordinator.sessionBelongsToCapture`.
    let generation: Int
    /// The caret position observed immediately before this session's FIRST unicode post — nil
    /// until then (Codex finding 3). Every later post/deletion requires the CURRENT caret to sit
    /// exactly at `caretAnchor + <UTF-16 length of ledger>`, an absolute, session-specific
    /// position — not just "some matching text sits before wherever the caret currently is",
    /// which a same-field, different-occurrence selection could satisfy.
    private(set) var caretAnchor: Int?
    /// The field's full value, snapshotted once, immediately after the first caret read succeeds
    /// (Codex finding 2) — before any typing. `readbackMatches`/`verifyBeforeDelete` use this to
    /// authenticate PROVENANCE (the current document is exactly this baseline with the ledger
    /// spliced in at the anchor), not just location (matching text sitting wherever the caret
    /// happens to be now, which pre-existing document text can satisfy just as well).
    private(set) var baselineValue: String?

    /// Fresh identity/security/collapsed-selection/caret read, done immediately before EVERY
    /// unicode post (Codex finding 2). `expectedCaret` is `caretAnchor + ledger UTF-16 length`,
    /// or nil for this session's very first post (no anchor yet, but the selection must still be
    /// collapsed). Returns the observed caret (which becomes `caretAnchor` on the first success)
    /// or nil if anything is unsafe/drifted/mismatched.
    private let writeSnapshotCaret: (InsertionTarget, Int?) -> Int?
    /// One fresh read of the field's full current value, called once, immediately after the first
    /// successful `writeSnapshotCaret` (Codex finding 2) — becomes `baselineValue`. `nil` fails
    /// the session closed (frozen) since no later delete could ever be proven safe without it.
    private let readBaselineValue: (InsertionTarget) -> String?
    private let verifyBeforeDelete: (InsertionTarget, String, Int, String) -> Bool

    init(
        target: InsertionTarget,
        generation: Int,
        writeSnapshotCaret: @escaping (InsertionTarget, Int?) -> Int? = { target, expectedCaret in
            Insertion.streamingWriteCaret(target: target, expectedCaret: expectedCaret)
        },
        readBaselineValue: @escaping (InsertionTarget) -> String? = { target in
            Insertion.streamingBaselineValue(target: target)
        },
        verifyBeforeDelete: @escaping (InsertionTarget, String, Int, String) -> Bool = { target, ledgerText, expectedCaret, baseline in
            guard let element = Insertion.streamingSafeElement(target: target) else { return false }
            return Insertion.readbackMatches(element: element, expectedTrailingText: ledgerText, expectedCaret: expectedCaret, baseline: baseline)
        }
    ) {
        self.target = target
        self.generation = generation
        self.writeSnapshotCaret = writeSnapshotCaret
        self.readBaselineValue = readBaselineValue
        self.verifyBeforeDelete = verifyBeforeDelete
    }

    var hasTypedAnything: Bool { !ledger.isEmpty }

    /// Freezes the session without touching the target — used both by a drifted/unsafe check and
    /// by `AppCoordinator` when the live-audio fan-out overflows (Codex finding 8): the Recording
    /// keeps capturing normally, but no further partials are typed.
    func freeze() {
        isFrozen = true
    }

    /// Feeds one APPEND-ONLY confirmed-transcript emission from a `StreamingTranscriptionEngine`
    /// (`confirmedText` is the full confirmed transcript so far, per that protocol's contract).
    /// Types only the new suffix beyond what's already on the ledger. A no-op once frozen.
    func receivePartial(_ confirmedText: String) {
        guard !isFrozen else { return }
        let confirmed = Array(confirmedText)
        // Defensive append-only guard, mirroring `StreamingAppendOnly`: if the incoming text
        // doesn't extend exactly what's already on the ledger, don't type anything — never
        // rewrite characters already on screen.
        guard confirmed.count > ledger.count, Array(confirmed.prefix(ledger.count)) == ledger else { return }
        let delta = String(confirmed[ledger.count...])
        // Codex findings 2, 3: ONE fresh read, immediately before this post — identity, security,
        // a COLLAPSED selection, and (once there is an anchor) the caret sitting exactly where
        // this session's own typing left it. A selection created after Recording start (the user
        // selected an existing word in the same field) fails this and freezes instead of
        // overwriting it. The very first post still runs this with `expectedCaret == nil`.
        let expectedCaret = caretAnchor.map { $0 + Self.utf16Count(of: ledger) }
        guard let caret = writeSnapshotCaret(target, expectedCaret) else {
            isFrozen = true
            return
        }
        let isFirstPost = caretAnchor == nil
        if isFirstPost {
            // Codex finding 2: captured HERE, immediately after the first caret read confirms a
            // collapsed selection at this exact position — before any typing, so it can never
            // include this session's own text.
            guard let baseline = readBaselineValue(target) else {
                isFrozen = true
                return
            }
            baselineValue = baseline
        }
        guard Self.typeText(delta) else {
            isFrozen = true
            return
        }
        if isFirstPost { caretAnchor = caret }
        ledger.append(contentsOf: delta)
    }

    /// Called once, on Done/Raw/Cancel. `refinedText`/`rawText` are the same post-processed/raw
    /// outputs the existing batch pipeline already produces at stop.
    ///
    /// Immediately before the only destructive action this session ever takes (Codex findings 2,
    /// 3, 5), a fresh identity/security/readback check runs for EVERY path here, including
    /// Cancel — a prior version backspaced unconditionally on Cancel before this check existed,
    /// and finalization could backspace whatever the CURRENT focus was without re-validating the
    /// target first. `CGEvent.post` is not atomic with this check — a residual race remains
    /// between this read and the synthesized backspace/type keystrokes themselves; that window
    /// can't be closed further without a delivery-confirmation API this platform doesn't expose.
    func finalize(action: FinalizeAction, refinedText: String, rawText: String) -> Outcome {
        // Codex finding 3: verification requires the CURRENT caret to sit exactly at
        // `caretAnchor + ledger UTF-16 length`, not just matching text somewhere before wherever
        // the caret happens to be right now. Codex finding 2: `verifyBeforeDelete` also requires
        // `baselineValue` — a non-empty ledger with no anchor OR no baseline is an invariant
        // violation (both are always captured together, on the first successful post) and fails
        // closed. Only actually reads back (AX + CGEvent-adjacent) when the ledger is non-empty —
        // `verificationOutcome` below is the pure decision core of what happens with that readback
        // result.
        let readbackMatches: Bool
        if ledger.isEmpty {
            readbackMatches = true
        } else if let anchor = caretAnchor, let baseline = baselineValue {
            readbackMatches = verifyBeforeDelete(target, String(ledger), anchor + Self.utf16Count(of: ledger), baseline)
        } else {
            readbackMatches = false
        }
        let verified = Self.verificationOutcome(
            ledgerIsEmpty: ledger.isEmpty, hasCaretAnchor: caretAnchor != nil, readbackMatches: readbackMatches
        )
        // Codex finding 1: an empty ledger means nothing was ever typed, so there's nothing to
        // backspace — but `.insert` is still this session's only OTHER consequential action (an
        // ordinary pasteboard paste at whatever currently has focus), and none of the streaming
        // security checks above ever ran for it (they're all gated on a non-empty ledger). One
        // fresh collapsed-selection/secure/identity read, immediately before accepting that
        // branch, closes both concrete failures Codex found: a selection the user made after
        // Recording started would otherwise be silently replaced by the paste, and a field that
        // turned secure since Recording start would otherwise receive the refined text via the
        // ordinary (non-streaming) paste path, which never checks for that. Skipped for Cancel —
        // an empty ledger on Cancel never inserts anything regardless, so there's nothing this
        // read could gate.
        let emptyLedgerInsertSafe = (ledger.isEmpty && action != .cancel) ? (writeSnapshotCaret(target, nil) != nil) : true
        let (shouldBackspace, shouldFreeze, outcome) = Self.finalizeDecision(
            action: action, refinedText: refinedText, rawText: rawText,
            isFrozen: isFrozen, ledgerCount: ledger.count, verified: verified,
            emptyLedgerInsertSafe: emptyLedgerInsertSafe
        )
        if shouldFreeze { isFrozen = true }
        if shouldBackspace { backspaceLedger() }
        if case .clipboardOnly(let text) = outcome { Self.putOnClipboard(text) }
        return outcome
    }

    /// Pure decision core of `finalize`'s verification step (Codex finding 3), factored out so
    /// the caret-anchor invariant is directly unit-testable without a live AX session. A
    /// non-empty ledger with no anchor set is an invariant violation (the anchor is always
    /// captured on the first successful post, before the ledger ever grows past zero) and fails
    /// closed rather than trusting an unverifiable state — same fail-closed-on-doubt shape as
    /// `Insertion.secureCheckResult`.
    nonisolated static func verificationOutcome(ledgerIsEmpty: Bool, hasCaretAnchor: Bool, readbackMatches: Bool) -> Bool {
        guard !ledgerIsEmpty else { return true }
        guard hasCaretAnchor else { return false }
        return readbackMatches
    }

    /// Pure decision core of `finalize` (Codex findings 1, 2, 3, 5) — every branch is a value
    /// computation with no CGEvent/AX side effects, so it's directly unit-testable (mirrors
    /// `Insertion.classifyPreflightFailure`'s split of decision from effect). `verified` is the
    /// caller's already-computed readback+identity+security check — trivially true when
    /// `ledgerCount == 0` (nothing to verify, nothing to delete). `emptyLedgerInsertSafe` is the
    /// caller's already-computed fresh collapsed-selection/secure/identity check (Codex finding
    /// 1) — only consulted when `ledgerCount == 0`; irrelevant otherwise.
    nonisolated static func finalizeDecision(
        action: FinalizeAction,
        refinedText: String,
        rawText: String,
        isFrozen: Bool,
        ledgerCount: Int,
        verified: Bool,
        emptyLedgerInsertSafe: Bool
    ) -> (shouldBackspace: Bool, shouldFreeze: Bool, outcome: Outcome) {
        let outputText = action == .raw ? rawText : refinedText
        func leaveUntouched() -> Outcome {
            action == .cancel ? .none : .clipboardOnly(outputText)
        }
        guard !isFrozen, ledgerCount <= replaceCap else {
            // Frozen (drifted/unsafe target), or `⌫ × 2000` is slow and visually violent — skip
            // the replace entirely, keep the typed text on screen, hand the refined text to the
            // caller for the clipboard. Never for Cancel: leave the typed text alone, don't touch
            // the clipboard.
            return (false, false, leaveUntouched())
        }
        guard ledgerCount > 0 else {
            // Nothing was ever typed — no backspace needed. But `.insert` (Done/Raw) is still this
            // session's only OTHER consequential action and gets none of the checks above for
            // free (Codex finding 1) — require the caller's fresh check to have passed, else fall
            // back to clipboard-only same as an unverified non-empty ledger.
            if action == .cancel { return (false, false, .none) }
            guard emptyLedgerInsertSafe else { return (false, false, leaveUntouched()) }
            return (false, false, outputText.isEmpty ? .none : .insert(outputText))
        }
        guard verified else {
            // The ledger's claimed text isn't actually sitting before the caret right now (drift,
            // now-secure, or an app/IME/autocomplete transformed what was typed) — never
            // backspace an unverified count.
            return (false, true, leaveUntouched())
        }
        if action == .cancel { return (true, false, .none) }
        return (true, false, outputText.isEmpty ? .none : .insert(outputText))
    }

    /// UTF-16 length of the ledger (Codex finding 3's caret-anchor arithmetic) — AX's native
    /// indexing, matching `NSString`, since grapheme clusters don't map 1:1 to UTF-16 code units.
    nonisolated private static func utf16Count(of characters: [Character]) -> Int {
        String(characters).utf16.count
    }

    private func backspaceLedger() {
        guard !ledger.isEmpty else { return }
        Self.postBackspaces(ledger.count)
        ledger.removeAll()
    }

    private static func putOnClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Types `text` at the current keyboard focus via a synthesized Unicode key event — not the
    /// pasteboard. The underlying virtual key code is irrelevant: `keyboardSetUnicodeString`
    /// overrides the character payload regardless of which physical key the event nominally
    /// represents. `CGEvent.post` returning `true` only means an event was created and queued —
    /// never that the target actually consumed it unmodified (Codex finding 3); `receivePartial`
    /// trusts the ledger it appends here as a claim, and `finalize` re-verifies that claim via AX
    /// readback before ever deleting it.
    @discardableResult
    nonisolated private static func typeText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return false }
        let utf16 = Array(text.utf16)
        keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        let location = CGEventTapLocation.cghidEventTap
        keyDown.post(tap: location)
        keyUp.post(tap: location)
        return true
    }

    nonisolated private static func postBackspaces(_ count: Int) {
        guard count > 0, let source = CGEventSource(stateID: .hidSystemState) else { return }
        let deleteKeyCode: CGKeyCode = 51 // kVK_Delete
        let location = CGEventTapLocation.cghidEventTap
        for _ in 0..<count {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: false)
            else { continue }
            keyDown.post(tap: location)
            keyUp.post(tap: location)
        }
    }
}
