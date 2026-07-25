import CryptoKit
import Foundation

@MainActor
struct SelectionSnapshot {
    let target: InsertionTarget
    let range: NSRange
    let text: String
    let fingerprint: Data
    /// Set ONLY when this snapshot was produced by `CorrectionTargeting.selectRecentInsertion`
    /// (Correction Loop signal B's fallback) — the dictation that inserted the text this snapshot
    /// selects. `nil` for an ordinary manual selection. Codex finding 14: carried through from the
    /// EXACT call that captured this selection, rather than re-derived later by comparing
    /// `text`/`range.location` against `RecentInsertionStore`'s CURRENT state — a manual Voice
    /// Edit selection in a DIFFERENT document that happens to contain identical text at the same
    /// offset previously matched that re-derivation and recorded correction evidence against the
    /// wrong row.
    var correctionDictationID: Int64?

    nonisolated static func fingerprint(for text: String) -> Data {
        Data(SHA256.hash(data: Data(text.utf8)))
    }
}
