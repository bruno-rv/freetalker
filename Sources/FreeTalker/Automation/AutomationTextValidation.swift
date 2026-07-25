import Foundation

/// Codex round-1 Finding 3 (HIGH, unbounded concurrent work): `clean up`'s text and template-name
/// parameters had no bound, so a caller could hand FreeTalker a multi-megabyte payload. Pure and
/// `nonisolated` so it's testable, and checked BEFORE `suspendExecution()` in `CleanUpTextCommand`
/// so a rejected call never suspends at all.
enum AutomationTextValidation {
    /// ~200 KB of UTF-8 text — comfortably larger than anything a person would paste through
    /// Shortcuts for "clean up," but bounds the multi-megabyte-payload class of input this finding
    /// describes at the cheapest possible check, before any prompt construction or network call.
    static let maximumCleanUpTextBytes = 200_000

    static func validateCleanUpText(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationError.emptyText
        }
        guard text.utf8.count <= maximumCleanUpTextBytes else {
            throw AutomationError.textTooLarge
        }
    }

    /// Reuses `BackupBundleBounds.maxTemplateNameBytes` — the same 500-byte limit already enforced
    /// on every Template name stored in FreeTalker, so a name automation is allowed to look up can
    /// never be longer than a name that could actually exist.
    static func validateTemplateName(_ name: String) throws {
        guard name.utf8.count <= BackupBundleBounds.maxTemplateNameBytes else {
            throw AutomationError.invalidInput("The template name is too long.")
        }
    }
}
