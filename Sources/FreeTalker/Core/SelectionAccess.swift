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

        // Accessibility has no compare-and-swap operation. Reasserting the exact captured range
        // would itself be an unsafe write before validation. A second fully bracketed read,
        // followed directly by one AXSelectedText set on that validated element, minimizes (but
        // cannot remove) the final race window without mutating any rejected target.
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
            // Round 3 findings 1 & 4 (STEP 2 of the fix): the document discriminator is checked
            // ONLY for Correction Loop signal B's fallback snapshot (`SelectionSnapshot.
            // correctionDictationID != nil`, set exclusively by `CorrectionTargeting.
            // selectRecentInsertion`). Ordinary manual Voice Edit — the vast majority of
            // `replace()` calls — never captured a discriminator FOR THIS PURPOSE and keeps
            // `main`'s plain element/window/range/text revalidation; applying it there too was
            // Round 3 finding 4: an SPA rewriting its URL mid-instruction (no target change at
            // all) failed a manual edit as `.targetChanged`.
            documentMatches: snapshot.correctionDictationID == nil
                ? true
                : Self.correctionFallbackDocumentMatches(expected: snapshot.target.document, current: selection.target.document),
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

    /// STEP 3 of the Round 3 fix (finding 2): a `kAXDocumentAttribute` value alone never proves
    /// document identity when it's URL-shaped — Chromium (and every Chromium-derived browser)
    /// exposes that attribute as the tab's page URL, and a DUPLICATED tab shares the exact same
    /// URL as its original while being a genuinely different, recycled-element document. Trusting
    /// a URL-shaped MATCH as proof of "same document" is exactly the hole finding 2 identified, so
    /// this refuses (fails closed) whenever the remembered discriminator is URL-shaped, regardless
    /// of whether it currently matches — refusing an ambiguous correction-fallback target is the
    /// correct, deliberately conservative outcome; the alternative is replacing text in the wrong
    /// tab. No per-tab-identity machinery (e.g. reading the selected tab's own AX element) is
    /// built to chase a stronger signal here. A non-URL discriminator (an app exposing a genuine,
    /// non-URL per-document token) is still trusted via plain equality. `expected == nil` (no
    /// discriminator was ever captured) stays permissive, same as every other identity check here.
    nonisolated private static func correctionFallbackDocumentMatches(expected: String?, current: String?) -> Bool {
        guard let expected else { return true }
        guard !Self.isURLShaped(expected) else { return false }
        return expected == current
    }

    nonisolated private static func isURLShaped(_ value: String) -> Bool {
        URLComponents(string: value)?.scheme != nil
    }

    nonisolated static func revalidationError(
        appMatches: Bool,
        elementMatches: Bool,
        windowMatches: Bool,
        documentMatches: Bool = true,
        expectedRange: NSRange,
        currentRange: NSRange?,
        expectedFingerprint: Data,
        currentText: String?
    ) -> SelectionAccessError? {
        guard appMatches, elementMatches, windowMatches, documentMatches else { return .targetChanged }
        guard currentRange == expectedRange,
              let currentText,
              SelectionSnapshot.fingerprint(for: currentText) == expectedFingerprint else {
            return .selectionChanged
        }
        return nil
    }
}
