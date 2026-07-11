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
final class SelectionAccess: SelectionAccessing {
    private let adapter: SystemAccessibilityNodeAdapter

    init(adapter: SystemAccessibilityNodeAdapter = SystemAccessibilityNodeAdapter()) {
        self.adapter = adapter
    }

    func capture() throws -> SelectionSnapshot {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let target = Insertion.snapshotTarget(app: app),
              let element = target.focusedElement else {
            throw SelectionAccessError.noFrontmostApplication
        }
        guard !adapter.isSecure(element) else { throw SelectionAccessError.secureField }
        guard adapter.isEditable(element),
              let range = adapter.selectedTextRange(of: element), range.length > 0,
              let text = adapter.stringAttribute(kAXSelectedTextAttribute, from: element), !text.isEmpty else {
            throw SelectionAccessError.noEditableSelection
        }
        return SelectionSnapshot(
            target: target,
            range: range,
            text: text,
            fingerprint: SelectionSnapshot.fingerprint(for: text)
        )
    }

    func replace(_ snapshot: SelectionSnapshot, with text: String) throws {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let current = Insertion.snapshotTarget(app: app),
              let element = current.focusedElement else {
            throw SelectionAccessError.targetChanged
        }
        guard !adapter.isSecure(element) else { throw SelectionAccessError.secureField }
        let appMatches = current.pid == snapshot.target.pid
            && current.bundleID == snapshot.target.bundleID
        let elementMatches = snapshot.target.focusedElement.map { CFEqual($0, element) } ?? false
        let windowMatches: Bool
        if let expected = snapshot.target.window, let actual = current.window {
            windowMatches = CFEqual(expected, actual)
        } else {
            windowMatches = snapshot.target.window == nil && current.window == nil
        }
        let range = adapter.selectedTextRange(of: element)
        let currentText = adapter.stringAttribute(kAXSelectedTextAttribute, from: element)
        if let error = Self.revalidationError(
            appMatches: appMatches,
            elementMatches: elementMatches,
            windowMatches: windowMatches,
            expectedRange: snapshot.range,
            currentRange: range,
            expectedFingerprint: snapshot.fingerprint,
            currentText: currentText
        ) { throw error }
        guard adapter.replaceSelectedText(of: element, with: text) else {
            throw SelectionAccessError.replacementFailed
        }
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
