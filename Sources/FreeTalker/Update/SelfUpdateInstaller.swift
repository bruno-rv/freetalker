import Foundation

/// Swaps a verified, staged `FreeTalker.app` into the install location, atomically per step and
/// with rollback on any failure. Both file moves (`backup` and `promote`) must land on the SAME
/// volume as `installedPath` — `SelfUpdater` stages the download in a hidden directory right
/// next to the installed bundle (not `/tmp`) specifically so `FileManager.moveItem` resolves to
/// a single `rename(2)` rather than a slow, non-atomic copy-then-delete. See
/// `BRAINSTORM_INSTALL_AND_UPDATES.md`'s "closes a hazard" note: unlike the old `make app`
/// overwrite (which deleted the installed bundle before the new one was known to work), this
/// never removes a working install before its replacement is fully in place, and always tries
/// to restore the original if the promotion step fails.
enum SelfUpdateInstaller {
    enum SwapResult: Equatable {
        case success
        /// Promotion failed after the original was backed up, but the original was restored —
        /// the user is left exactly where they started.
        case rolledBack
        /// Promotion failed AND restoring the backup also failed — the worst case, surfaced
        /// distinctly so the caller can tell the user exactly where their old app went.
        case rollbackFailed
    }

    /// File primitives injected so this algorithm is unit-testable against an in-memory fake
    /// filesystem, without touching a real `.app` bundle — see `SelfUpdateInstallerTests`.
    struct FileOps {
        var moveItem: (URL, URL) throws -> Void
        var removeItem: (URL) throws -> Void
        var fileExists: (URL) -> Bool
    }

    /// Moves the currently-installed bundle aside, promotes the staged (already verified)
    /// bundle into its place, then deletes the backup. On any failure it attempts to restore
    /// the original from the backup before returning.
    static func swap(
        installedPath: URL,
        stagedPath: URL,
        backupPath: URL,
        ops: FileOps
    ) -> SwapResult {
        let hadExistingInstall = ops.fileExists(installedPath)
        if hadExistingInstall {
            do {
                try ops.moveItem(installedPath, backupPath)
            } catch {
                // Nothing was moved yet — installedPath is untouched, nothing to roll back.
                return .rollbackFailed
            }
        }

        do {
            try ops.moveItem(stagedPath, installedPath)
        } catch {
            guard hadExistingInstall else { return .rollbackFailed }
            do {
                try ops.moveItem(backupPath, installedPath)
                return .rolledBack
            } catch {
                return .rollbackFailed
            }
        }

        if hadExistingInstall {
            try? ops.removeItem(backupPath)
        }
        return .success
    }
}
