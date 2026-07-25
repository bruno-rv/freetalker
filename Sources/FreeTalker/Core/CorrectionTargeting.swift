import AppKit
import ApplicationServices

/// Shared targeting helper for Correction Loop signals A (hotkey panel) and B (spoken correction):
/// given the remembered `RecentInsertion`, proves the live document still contains it unmodified —
/// reusing `Insertion.streamingSafeElement` (identity/security, fresh) and `Insertion.
/// documentMatchesBaselinePlusLedger` (the exact provenance check streaming's own finalize-time
/// readback already uses), not a second implementation of either — and, only if that holds,
/// LIVE-SELECTS the exact range via `kAXSelectedTextRangeAttribute`. That's the whole trick: once
/// the range is genuinely selected, the EXISTING `SelectionAccess`/`VoiceEditCoordinator` machinery
/// (preview, confirm, drift-refusal) captures and replaces it exactly as if the user had
/// highlighted it themselves — no parallel replace path.
enum CorrectionTargeting {
    /// `nil` (drifted, unreadable, secure, or identity changed) fails closed: no AX write happens,
    /// nothing is selected, nothing is touched.
    @MainActor
    static func selectRecentInsertion(_ recent: RecentInsertion) -> SelectionSnapshot? {
        guard !recent.text.isEmpty else { return nil }
        guard let element = Insertion.streamingSafeElement(target: recent.target) else { return nil }
        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let current = valueRef as? String else { return nil }
        let ledger = Array(recent.text.utf16)
        guard Insertion.documentMatchesBaselinePlusLedger(
            current: Array(current.utf16), baseline: Array(recent.baselineValue.utf16),
            ledger: ledger, anchor: recent.anchor
        ) else { return nil }

        var range = CFRange(location: recent.anchor, length: ledger.count)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success else { return nil }

        return SelectionSnapshot(
            target: recent.target, range: NSRange(location: recent.anchor, length: ledger.count),
            text: recent.text, fingerprint: SelectionSnapshot.fingerprint(for: recent.text)
        )
    }
}
