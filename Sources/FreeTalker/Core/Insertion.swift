import AppKit
import ApplicationServices
import CoreGraphics

/// Inserts the Refined Output at the cursor of the frontmost app via the pasteboard +
/// synthetic ⌘V, restoring the previous pasteboard contents afterward. See PLAN.md step 6.
enum Insertion {
    /// Returns true if a synthetic ⌘V was posted. Skips posting (leaving the text on the
    /// pasteboard for a manual paste) if the frontmost app reports no focused UI element, since
    /// pasting into nothing would silently strand the dictated text after restoring the old
    /// clipboard. On CGEvent post failure, the text is also left on the pasteboard.
    @discardableResult
    static func insert(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let savedItems: [[NSPasteboard.PasteboardType: Data]] = pasteboard.pasteboardItems?.map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCountAfterWrite = pasteboard.changeCount

        guard isEditableFocusedElement() else {
            // No focused element, or AX affirmatively says it's not a text control — leave our
            // text on the pasteboard and don't touch it further. See Round 2 Codex finding 1.
            return false
        }

        let posted = postCommandV()

        if posted {
            // Timed restore: deliberate, logged decision — a residual race remains if the target
            // app is slow to read the pasteboard, but a completion signal isn't available via
            // public API. 1.0s (up from 0.3s) narrows the window; changeCount guard still skips
            // the restore if anything else wrote to the pasteboard first. See Round 1 Codex
            // finding 5 / Round 2 Codex finding 2.
            // ponytail: timed restore, residual race accepted for personal use + upgrade path:
            // skip restore option in Settings.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard pasteboard.changeCount == changeCountAfterWrite else { return }
                restore(savedItems, to: pasteboard)
            }
        }
        return posted
    }

    /// Checks whether the frontmost app's focused UI element is a plausible paste target: either
    /// AX reports its value as settable, or its role is a known text-bearing role. If AX can't
    /// answer conclusively (no focused element info, role unknown, settability unknown), this
    /// defaults to `true` — never blocking a paste on missing AX data, since losing dictated text
    /// is worse than an occasional paste into a non-text control. Only skips when AX
    /// affirmatively says the focused element is a known, non-text-settable control.
    // ponytail: permissive AX editability heuristic + upgrade path: per-app allowlist.
    private static func isEditableFocusedElement() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusResult == .success, let focusedRef else {
            // No focused element at all — nothing to paste into.
            return false
        }
        let element = focusedRef as! AXUIElement // swiftlint:disable:this force_cast

        var settable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        if settableResult == .success, settable.boolValue {
            return true
        }

        var roleRef: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXWebArea"]
        if roleResult == .success, let role = roleRef as? String {
            if textRoles.contains(role) { return true }
            if settableResult == .success {
                // Role known and value affirmatively not settable — a non-text control.
                return false
            }
        }

        // AX query errored or gave inconclusive info — permissive default.
        return true
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let newItems: [NSPasteboardItem] = items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(newItems)
    }

    private static func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        let location = CGEventTapLocation.cghidEventTap
        keyDown.post(tap: location)
        keyUp.post(tap: location)
        return true
    }
}
