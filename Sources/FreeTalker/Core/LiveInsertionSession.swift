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

    private let isSafeToType: (InsertionTarget) -> Bool
    private let verifyBeforeDelete: (InsertionTarget, String) -> Bool

    init(
        target: InsertionTarget,
        generation: Int,
        isSafeToType: @escaping (InsertionTarget) -> Bool = { Insertion.streamingSafeElement(target: $0) != nil },
        verifyBeforeDelete: @escaping (InsertionTarget, String) -> Bool = { target, ledgerText in
            guard let element = Insertion.streamingSafeElement(target: target) else { return false }
            return Insertion.readbackMatches(element: element, expectedTrailingText: ledgerText)
        }
    ) {
        self.target = target
        self.generation = generation
        self.isSafeToType = isSafeToType
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
        guard isSafeToType(target) else {
            isFrozen = true
            return
        }
        let confirmed = Array(confirmedText)
        // Defensive append-only guard, mirroring `StreamingAppendOnly`: if the incoming text
        // doesn't extend exactly what's already on the ledger, don't type anything — never
        // rewrite characters already on screen.
        guard confirmed.count > ledger.count, Array(confirmed.prefix(ledger.count)) == ledger else { return }
        let delta = String(confirmed[ledger.count...])
        guard Self.typeText(delta) else {
            isFrozen = true
            return
        }
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
        let verified = ledger.isEmpty || verifyBeforeDelete(target, String(ledger))
        let (shouldBackspace, shouldFreeze, outcome) = Self.finalizeDecision(
            action: action, refinedText: refinedText, rawText: rawText,
            isFrozen: isFrozen, ledgerCount: ledger.count, verified: verified
        )
        if shouldFreeze { isFrozen = true }
        if shouldBackspace { backspaceLedger() }
        if case .clipboardOnly(let text) = outcome { Self.putOnClipboard(text) }
        return outcome
    }

    /// Pure decision core of `finalize` (Codex findings 1, 2, 3, 5) — every branch is a value
    /// computation with no CGEvent/AX side effects, so it's directly unit-testable (mirrors
    /// `Insertion.classifyPreflightFailure`'s split of decision from effect). `verified` is the
    /// caller's already-computed readback+identity+security check — trivially true when
    /// `ledgerCount == 0` (nothing to verify, nothing to delete).
    nonisolated static func finalizeDecision(
        action: FinalizeAction,
        refinedText: String,
        rawText: String,
        isFrozen: Bool,
        ledgerCount: Int,
        verified: Bool
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
            // Nothing was ever typed — no destructive action, nothing to verify.
            if action == .cancel { return (false, false, .none) }
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
