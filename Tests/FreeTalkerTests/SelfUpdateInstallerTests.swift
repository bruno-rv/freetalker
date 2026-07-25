import Foundation
import Testing
@testable import FreeTalker

/// Tiny in-memory fake filesystem — enough to drive `SelfUpdateInstaller.swap`'s three file
/// operations and inject failures at any point, without ever touching a real `.app` bundle.
private final class FakeFileSystem {
    private(set) var paths: Set<String>
    var failMoveFrom: String?
    var failRemove: String?

    init(existingPaths: Set<String>) {
        paths = existingPaths
    }

    func ops() -> SelfUpdateInstaller.FileOps {
        SelfUpdateInstaller.FileOps(
            moveItem: { [self] source, destination in
                if failMoveFrom == source.path {
                    throw CocoaError(.fileWriteUnknown)
                }
                guard paths.contains(source.path) else { throw CocoaError(.fileNoSuchFile) }
                paths.remove(source.path)
                paths.insert(destination.path)
            },
            removeItem: { [self] target in
                if failRemove == target.path {
                    throw CocoaError(.fileWriteUnknown)
                }
                paths.remove(target.path)
            },
            fileExists: { [self] target in paths.contains(target.path) }
        )
    }
}

@Suite struct SelfUpdateInstallerTests {
    private let installed = URL(fileURLWithPath: "/Applications/FreeTalker.app")
    private let staged = URL(fileURLWithPath: "/Applications/.freetalker-update/extracted/FreeTalker.app")
    private let backup = URL(fileURLWithPath: "/Applications/.freetalker-update/backup.app")

    @Test func happyPathBacksUpPromotesAndDeletesTheBackup() {
        let fs = FakeFileSystem(existingPaths: [installed.path, staged.path])
        let result = SelfUpdateInstaller.swap(installedPath: installed, stagedPath: staged, backupPath: backup, ops: fs.ops())
        #expect(result == .success)
        #expect(fs.paths.contains(installed.path))
        #expect(!fs.paths.contains(staged.path))
        #expect(!fs.paths.contains(backup.path))
    }

    @Test func firstInstallWithNoExistingBundleSkipsBackupEntirely() {
        // No prior install (fresh /Applications) — nothing to back up, promotion still succeeds.
        let fs = FakeFileSystem(existingPaths: [staged.path])
        let result = SelfUpdateInstaller.swap(installedPath: installed, stagedPath: staged, backupPath: backup, ops: fs.ops())
        #expect(result == .success)
        #expect(fs.paths.contains(installed.path))
    }

    /// The core safety property: if promotion fails after backup succeeded, the original app
    /// is restored — the currently-installed app is never left missing or half-written. A
    /// verifier that skipped this rollback path would still pass every OTHER test in this
    /// file; only this one fails if the rollback logic is removed.
    @Test func promotionFailureAfterBackupRestoresTheOriginal() {
        let fs = FakeFileSystem(existingPaths: [installed.path, staged.path])
        fs.failMoveFrom = staged.path
        let result = SelfUpdateInstaller.swap(installedPath: installed, stagedPath: staged, backupPath: backup, ops: fs.ops())
        #expect(result == .rolledBack)
        #expect(fs.paths.contains(installed.path))
        #expect(!fs.paths.contains(backup.path))
    }

    @Test func backupFailureLeavesTheOriginalInstallUntouched() {
        let fs = FakeFileSystem(existingPaths: [installed.path, staged.path])
        fs.failMoveFrom = installed.path
        let result = SelfUpdateInstaller.swap(installedPath: installed, stagedPath: staged, backupPath: backup, ops: fs.ops())
        #expect(result == .rollbackFailed)
        // The original was never moved — it's still exactly where it was.
        #expect(fs.paths.contains(installed.path))
        #expect(!fs.paths.contains(backup.path))
    }

    /// Worst case: promotion fails AND restoring the backup also fails. Distinguishable from
    /// `.rolledBack` so the caller can tell the user their previous app needs manual recovery —
    /// and, critically (Finding 5), `swap` itself must never have removed the backup in this
    /// case: it's the user's ONLY surviving copy of their previous app. A verifier that only
    /// checked `result == .rollbackFailed` (the original form of this test) would still pass if
    /// `swap` started deleting `backupPath` on this path — only the explicit path assertions
    /// below catch that.
    @Test func promotionAndRollbackBothFailingIsReportedDistinctlyAndPreservesTheBackup() {
        let fs = FakeFileSystem(existingPaths: [installed.path, staged.path])
        fs.failMoveFrom = staged.path
        let originalOps = fs.ops()
        // Compose: fail the staged->installed move (triggers rollback attempt), then ALSO fail
        // the backup->installed restore move.
        let failingOps = SelfUpdateInstaller.FileOps(
            moveItem: { source, destination in
                if source.path == backup.path { throw CocoaError(.fileWriteUnknown) }
                try originalOps.moveItem(source, destination)
            },
            removeItem: originalOps.removeItem,
            fileExists: originalOps.fileExists
        )
        let result = SelfUpdateInstaller.swap(installedPath: installed, stagedPath: staged, backupPath: backup, ops: failingOps)
        #expect(result == .rollbackFailed)
        // The user's original app must still be recoverable at `backupPath` — this is the
        // property `SelfUpdater.shouldPreserveStagingRoot`/its staging-root `defer` depend on:
        // if `swap` had removed it here, preserving the staging directory would preserve
        // nothing.
        #expect(fs.paths.contains(backup.path))
        #expect(!fs.paths.contains(installed.path))
    }

    /// A failure removing the now-redundant backup after a successful promotion is not itself a
    /// failure — the new app is already correctly installed, cleanup is best-effort.
    @Test func backupCleanupFailureAfterSuccessIsStillReportedAsSuccess() {
        let fs = FakeFileSystem(existingPaths: [installed.path, staged.path])
        fs.failRemove = backup.path
        let result = SelfUpdateInstaller.swap(installedPath: installed, stagedPath: staged, backupPath: backup, ops: fs.ops())
        #expect(result == .success)
        #expect(fs.paths.contains(installed.path))
    }
}
