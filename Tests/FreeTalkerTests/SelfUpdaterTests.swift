import Foundation
import Testing
@testable import FreeTalker

@Suite struct SelfUpdaterTests {
    @Test func evaluateReportsAvailableWhenManifestIsNewer() {
        let manifest = UpdateManifest(version: "v1.3.0", assetURL: URL(string: "https://example.com/a.zip")!, sha256: "deadbeef")
        let result = SelfUpdater.evaluate(current: SemanticVersion(major: 1, minor: 2, patch: 0), manifest: manifest)
        #expect(result == .available(manifest: manifest))
    }

    @Test func evaluateReportsUpToDateWhenCurrentIsNewerOrEqual() {
        let manifest = UpdateManifest(version: "v1.2.0", assetURL: URL(string: "https://example.com/a.zip")!, sha256: "deadbeef")
        #expect(SelfUpdater.evaluate(current: SemanticVersion(major: 1, minor: 2, patch: 0), manifest: manifest) == .upToDate)
        #expect(SelfUpdater.evaluate(current: SemanticVersion(major: 1, minor: 3, patch: 0), manifest: manifest) == .upToDate)
    }

    @Test func evaluateFailsClosedOnUnparsableManifestVersion() {
        let manifest = UpdateManifest(version: "not-a-version", assetURL: URL(string: "https://example.com/a.zip")!, sha256: "deadbeef")
        guard case .unavailable = SelfUpdater.evaluate(current: SemanticVersion(major: 0, minor: 0, patch: 0), manifest: manifest) else {
            Issue.record("expected .unavailable for an unparsable manifest version")
            return
        }
    }

    /// Cross-checks `SelfUpdater.sha256Hex` against the actual `shasum` binary
    /// `scripts/release.sh` shells out to — never a hand-invented expected digest.
    @Test func sha256HexMatchesTheRealShasumTool() throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        let payload = Data("FreeTalker self-update checksum test — \(UUID())".utf8)
        try payload.write(to: tempFile)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", tempFile.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let expected = output.split(separator: " ").first.map(String.init)

        #expect(SelfUpdater.sha256Hex(of: payload) == expected)
    }

    // MARK: shouldPreserveStagingRoot (Finding 5 — rollback-failure data loss)

    /// The one outcome that must preserve staging: `SelfUpdateInstaller.swap` already moved the
    /// user's original app to `backupPath` (inside staging) and then failed to put it back. A
    /// verifier that dropped this guard would still pass every other case here — only this one
    /// fails if the guard is removed.
    @Test func shouldPreserveStagingRootOnlyWhenRollbackFailed() {
        #expect(SelfUpdater.shouldPreserveStagingRoot(after: .rollbackFailed))
        #expect(!SelfUpdater.shouldPreserveStagingRoot(after: .success))
        #expect(!SelfUpdater.shouldPreserveStagingRoot(after: .rolledBack))
        #expect(!SelfUpdater.shouldPreserveStagingRoot(after: nil))
    }

    // MARK: validateStagedVersion (Finding 4 — manifest/artifact version binding)

    @Test func validateStagedVersionAcceptsAMatchingNewerVersion() {
        #expect(SelfUpdater.validateStagedVersion(
            stagedVersionString: "1.3.0", manifestVersion: "v1.3.0", currentVersion: SemanticVersion(major: 1, minor: 2, patch: 0)
        ) == .ok)
    }

    @Test func validateStagedVersionRejectsUnreadableOrUnparsableStampedVersion() {
        #expect(SelfUpdater.validateStagedVersion(
            stagedVersionString: nil, manifestVersion: "v1.3.0", currentVersion: SemanticVersion(major: 1, minor: 2, patch: 0)
        ) == .unreadable)
        #expect(SelfUpdater.validateStagedVersion(
            stagedVersionString: "not-a-version", manifestVersion: "v1.3.0", currentVersion: SemanticVersion(major: 1, minor: 2, patch: 0)
        ) == .unreadable)
    }

    /// The core replay/downgrade guard: a manifest claiming an inflated version whose asset ZIP
    /// actually stamps an OLD version must be rejected — this is what stops "claim v999.0.0,
    /// ship the v1.0.0 artifact" from ever installing the old artifact.
    @Test func validateStagedVersionRejectsAStampedVersionThatDoesNotMatchTheManifestClaim() {
        let result = SelfUpdater.validateStagedVersion(
            stagedVersionString: "1.0.0", manifestVersion: "v999.0.0", currentVersion: SemanticVersion(major: 1, minor: 2, patch: 0)
        )
        guard case .mismatchedManifest(let staged, let claimed) = result else {
            Issue.record("expected .mismatchedManifest, got \(result)")
            return
        }
        #expect(staged == "1.0.0")
        #expect(claimed == "v999.0.0")
    }

    /// Replaying the currently-installed ZIP under a fabricated newer manifest version: the
    /// stamped version matches the (fabricated) claim, but isn't newer than what's running —
    /// this is the case that would otherwise loop forever without ever actually updating.
    @Test func validateStagedVersionRejectsAVersionThatIsNotNewerThanCurrent() {
        let result = SelfUpdater.validateStagedVersion(
            stagedVersionString: "1.2.0", manifestVersion: "v1.2.0", currentVersion: SemanticVersion(major: 1, minor: 2, patch: 0)
        )
        guard case .notNewer = result else {
            Issue.record("expected .notNewer, got \(result)")
            return
        }
    }

    // MARK: containsSymlink (Finding 3 — symlinked .app swap-and-destroy)

    /// A plain directory tree with no symlinks anywhere — the shape of every real release —
    /// must never be rejected.
    @Test func containsSymlinkIsFalseForAnOrdinaryDirectoryTree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("FreeTalker.app/Contents/MacOS"), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: root.appendingPathComponent("FreeTalker.app/Contents/MacOS/FreeTalker"))
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(!SelfUpdater.containsSymlink(at: root))
    }

    /// Reproduces the actual attack: the top-level `.app` entry itself is a symlink to another
    /// real directory — exactly what `FreeTalker.app -> /Applications/FreeTalker.app` inside a
    /// malicious ZIP would extract to via `ditto`. A real symlink, not a hand-invented flag.
    @Test func containsSymlinkIsTrueWhenTheTopLevelAppEntryIsASymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let realTarget = root.appendingPathComponent("RealTarget.app")
        try FileManager.default.createDirectory(at: realTarget, withIntermediateDirectories: true)
        let symlinkedApp = root.appendingPathComponent("FreeTalker.app")
        try FileManager.default.createSymbolicLink(at: symlinkedApp, withDestinationURL: realTarget)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(SelfUpdater.containsSymlink(at: symlinkedApp))
    }

    /// A symlink nested deep inside an otherwise-ordinary bundle tree — the same escape, just
    /// not at the top level — must also be caught.
    @Test func containsSymlinkIsTrueForANestedSymlinkAnywhereInsideTheTree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let macOSDir = root.appendingPathComponent("FreeTalker.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        let elsewhere = root.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: macOSDir.appendingPathComponent("FreeTalker"), withDestinationURL: elsewhere
        )
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(SelfUpdater.containsSymlink(at: root))
    }

    // MARK: runProcess SIGKILL escalation (Finding 8 — unbounded smoke-test wait)

    /// A real child process that traps and ignores SIGTERM. Without the SIGKILL escalation this
    /// would hang for the full `timeout` (or forever, since `terminate()` alone can't force it),
    /// not just the short grace period — this is exactly the "hung child" scenario the fix
    /// closes, reproduced with a real ignoring process rather than an assumption about signals.
    @Test func runProcessEscalatesToSIGKILLWhenTheChildIgnoresSIGTERM() {
        // `exec` replaces the shell's own process image with `sleep` in place (same PID, no
        // fork) — SIG_IGN dispositions set before `exec` (unlike custom handlers) persist across
        // it, per POSIX, so the resulting single process genuinely ignores SIGTERM itself.
        // Without `exec`, `sh -c "trap '' TERM; sleep 30"` forks `sleep` as a CHILD of the
        // shell — killing only the shell's PID would leave that child running (and still
        // holding the pipe open), which isn't the scenario this test is about.
        let start = Date()
        let result = SelfUpdater.runProcess(
            "/bin/sh", ["-c", "trap '' TERM; exec sleep 30"], timeout: 0.3, killGracePeriod: 0.3
        )
        let elapsed = Date().timeIntervalSince(start)
        // The real claim: the child was killed by SIGKILL specifically, not merely that it
        // exited non-zero for some other reason. `Process.terminationStatus` for a
        // signal-terminated process IS the signal number (confirmed against
        // `Process.terminationReason == .uncaughtSignal` for this exact scenario), and `sleep`
        // never exits with status 9 on its own — the only way this child's status can equal
        // `SIGKILL` is if it was actually sent that signal. `trap '' TERM` makes SIGTERM alone
        // insufficient, so this also proves the escalation — not the initial `terminate()` —
        // is what ended it.
        #expect(result.status == SIGKILL)
        #expect(result.status != 0)
        // Secondary, coarser wall-clock bound: 0.3s timeout + 0.3s grace = 0.6s if the
        // escalation fires promptly. 2s is generous enough to absorb scheduler jitter without
        // being fooled by a real regression — if the escalation were removed entirely, this
        // child (ignoring SIGTERM, `exec`'d so no shell parent to reap it another way) would run
        // for the full 30s `sleep`, which blows well past this bound either way.
        #expect(elapsed < 2, "runProcess took \(elapsed)s — SIGKILL escalation did not bound the wait")
    }

    /// The real `dist/latest.json` produced by `scripts/release.sh v0.1.0 --dry-run` — not
    /// hand-invented, this is exactly what the release script writes.
    @Test func decodesTheManifestJSONShapeReleaseScriptWrites() throws {
        let json = """
        {
          "version": "v0.1.0",
          "assetURL": "https://github.com/bruno-rv/freetalker/releases/download/v0.1.0/FreeTalker-v0.1.0.app.zip",
          "sha256": "c1fc1ebc8e3d3c5194243090ac0f0207f62f880b38ad585d3320a36d1b49f9e7"
        }
        """
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        #expect(manifest.version == "v0.1.0")
        #expect(
            manifest.assetURL.absoluteString
                == "https://github.com/bruno-rv/freetalker/releases/download/v0.1.0/FreeTalker-v0.1.0.app.zip"
        )
        #expect(manifest.sha256 == "c1fc1ebc8e3d3c5194243090ac0f0207f62f880b38ad585d3320a36d1b49f9e7")
    }
}
