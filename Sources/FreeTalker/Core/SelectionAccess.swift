import AppKit
import ApplicationServices
import Foundation

enum SelectionAccessError: Error, Equatable {
    case noFrontmostApplication
    case noEditableSelection
    case secureField
    case targetChanged
    case selectionChanged
    case replacementFailed
}

@MainActor
protocol SelectionAccessing {
    func capture() throws -> SelectionSnapshot
    func replace(_ snapshot: SelectionSnapshot, with text: String) throws
}

@MainActor
protocol SelectionAccessibilityAdapting: AnyObject {
    func isSecure(_ element: AXUIElement) -> Bool
    func isEditable(_ element: AXUIElement) -> Bool
    func elementsEqual(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool
    func selectedTextRange(of element: AXUIElement) -> NSRange?
    func selectedText(of element: AXUIElement) -> String?
    func setSelectedTextRange(of element: AXUIElement, to range: NSRange) -> Bool
    func replaceSelectedText(of element: AXUIElement, with text: String) -> Bool
}

@MainActor
final class SelectionAccess: SelectionAccessing {
    private struct StableSelection {
        let target: InsertionTarget
        let range: NSRange
        let text: String
    }

    private let adapter: any SelectionAccessibilityAdapting
    private let targetProvider: @MainActor () -> InsertionTarget?

    init(
        adapter: any SelectionAccessibilityAdapting = SystemAccessibilityNodeAdapter(),
        targetProvider: @escaping @MainActor () -> InsertionTarget? = {
            NSWorkspace.shared.frontmostApplication.flatMap { Insertion.snapshotTarget(app: $0) }
        }
    ) {
        self.adapter = adapter
        self.targetProvider = targetProvider
    }

    func capture() throws -> SelectionSnapshot {
        let selection = try readStableSelection()
        return SelectionSnapshot(
            target: selection.target,
            range: selection.range,
            text: selection.text,
            fingerprint: SelectionSnapshot.fingerprint(for: selection.text)
        )
    }

    func replace(_ snapshot: SelectionSnapshot, with text: String) throws {
        let first = try readStableSelection()
        try validate(first, against: snapshot)
        guard let element = first.target.focusedElement,
              adapter.setSelectedTextRange(of: element, to: snapshot.range) else {
            throw SelectionAccessError.replacementFailed
        }

        // Accessibility has no compare-and-swap operation. Reasserting the exact captured range
        // and immediately performing a second fully bracketed read minimizes (but cannot remove)
        // the final race window before AXSelectedText is set.
        let final = try readStableSelection()
        try validate(final, against: snapshot)
        guard let finalElement = final.target.focusedElement,
              adapter.replaceSelectedText(of: finalElement, with: text) else {
            throw SelectionAccessError.replacementFailed
        }
    }

    private func readStableSelection() throws -> StableSelection {
        guard let before = targetProvider(), let element = before.focusedElement else {
            throw SelectionAccessError.noFrontmostApplication
        }
        guard !adapter.isSecure(element) else { throw SelectionAccessError.secureField }
        guard adapter.isEditable(element) else { throw SelectionAccessError.noEditableSelection }
        guard let range1 = adapter.selectedTextRange(of: element),
              let text1 = adapter.selectedText(of: element),
              let range2 = adapter.selectedTextRange(of: element),
              let text2 = adapter.selectedText(of: element),
              let after = targetProvider() else { throw SelectionAccessError.selectionChanged }
        guard targetsMatch(before, after) else { throw SelectionAccessError.targetChanged }
        guard range1 == range2, text1 == text2 else { throw SelectionAccessError.selectionChanged }
        guard range1.length > 0, !text1.isEmpty else { throw SelectionAccessError.noEditableSelection }
        return StableSelection(target: after, range: range1, text: text1)
    }

    private func validate(_ selection: StableSelection, against snapshot: SelectionSnapshot) throws {
        if let error = Self.revalidationError(
            appMatches: selection.target.pid == snapshot.target.pid
                && selection.target.bundleID == snapshot.target.bundleID,
            elementMatches: adapter.elementsEqual(selection.target.focusedElement, snapshot.target.focusedElement),
            windowMatches: adapter.elementsEqual(selection.target.window, snapshot.target.window),
            expectedRange: snapshot.range,
            currentRange: selection.range,
            expectedFingerprint: snapshot.fingerprint,
            currentText: selection.text
        ) { throw error }
    }

    private func targetsMatch(_ lhs: InsertionTarget, _ rhs: InsertionTarget) -> Bool {
        lhs.pid == rhs.pid && lhs.bundleID == rhs.bundleID
            && adapter.elementsEqual(lhs.focusedElement, rhs.focusedElement)
            && adapter.elementsEqual(lhs.window, rhs.window)
    }

    nonisolated static func revalidationError(
        appMatches: Bool,
        elementMatches: Bool,
        windowMatches: Bool,
        expectedRange: NSRange,
        currentRange: NSRange?,
        expectedFingerprint: Data,
        currentText: String?
    ) -> SelectionAccessError? {
        guard appMatches, elementMatches, windowMatches else { return .targetChanged }
        guard currentRange == expectedRange,
              let currentText,
              SelectionSnapshot.fingerprint(for: currentText) == expectedFingerprint else {
            return .selectionChanged
        }
        return nil
    }
}
