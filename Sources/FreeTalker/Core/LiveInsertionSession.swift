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
        /// The ledger was left on screen as-is (focus drift, or over the replace cap) — the
        /// caller should place `text` on the clipboard and surface a HUD hint. Never backspaced.
        case clipboardOnly(String)
        /// The ledger was backspaced away (or was already empty) and there is nothing further to
        /// insert — Cancel, or Done/Raw with empty output.
        case none
    }

    // ponytail: 400-char replace cap, raise if backspace batching proves fast
    static let replaceCap = 400

    private(set) var ledger: [Character] = []
    private(set) var isFrozen = false
    let target: InsertionTarget

    init(target: InsertionTarget) {
        self.target = target
    }

    var hasTypedAnything: Bool { !ledger.isEmpty }

    /// Feeds one APPEND-ONLY confirmed-transcript emission from a `StreamingTranscriptionEngine`
    /// (`confirmedText` is the full confirmed transcript so far, per that protocol's contract).
    /// Types only the new suffix beyond what's already on the ledger. A no-op once frozen.
    func receivePartial(_ confirmedText: String) {
        guard !isFrozen else { return }
        guard Insertion.targetStillFocused(target) else {
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
    func finalize(action: FinalizeAction, refinedText: String, rawText: String) -> Outcome {
        if action == .cancel {
            backspaceLedger()
            return .none
        }
        let outputText = action == .raw ? rawText : refinedText
        if isFrozen {
            // Never backspace a frozen ledger — it may be sitting in a different window/app than
            // the one the refined text belongs in.
            Self.putOnClipboard(outputText)
            return .clipboardOnly(outputText)
        }
        guard ledger.count <= Self.replaceCap else {
            // `⌫ × 2000` is slow and visually violent — skip the replace entirely, keep the raw
            // typed text on screen, hand the refined text to the caller for the clipboard.
            Self.putOnClipboard(outputText)
            return .clipboardOnly(outputText)
        }
        backspaceLedger()
        return outputText.isEmpty ? .none : .insert(outputText)
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
    /// represents.
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
