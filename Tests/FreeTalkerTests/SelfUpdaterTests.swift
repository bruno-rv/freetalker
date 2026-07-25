import Foundation
import Testing
@testable import FreeTalker

// `.serialized`: several tests here drive `SelfUpdater.performUpdate`, which claims a
// process-wide, in-process `UpdateInProgressGate` (see `SelfUpdater.swift`) — exactly the
// production behavior the concurrent-update fix relies on. Running this suite's tests in
// parallel (Swift Testing's default) would make that shared gate a source of cross-TEST
// flakiness having nothing to do with the production bug it exists to catch.
@Suite(.serialized) struct SelfUpdaterTests {
    @Test func evaluateReportsAvailableWhenManifestIsNewer() {
        let manifest = UpdateManifest(version: "v1.3.0", assetURL: URL(string: "https://example.com/a.zip")!, sha256: "deadbeef", signature: "sig")
        let result = SelfUpdater.evaluate(current: SemanticVersion(major: 1, minor: 2, patch: 0), manifest: manifest)
        #expect(result == .available(manifest: manifest))
    }

    @Test func evaluateReportsUpToDateWhenCurrentIsNewerOrEqual() {
        let manifest = UpdateManifest(version: "v1.2.0", assetURL: URL(string: "https://example.com/a.zip")!, sha256: "deadbeef", signature: "sig")
        #expect(SelfUpdater.evaluate(current: SemanticVersion(major: 1, minor: 2, patch: 0), manifest: manifest) == .upToDate)
        #expect(SelfUpdater.evaluate(current: SemanticVersion(major: 1, minor: 3, patch: 0), manifest: manifest) == .upToDate)
    }

    @Test func evaluateFailsClosedOnUnparsableManifestVersion() {
        let manifest = UpdateManifest(version: "not-a-version", assetURL: URL(string: "https://example.com/a.zip")!, sha256: "deadbeef", signature: "sig")
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
        // `.backupFailed` (Finding 9) never creates a backup in the first place — nothing in
        // staging is unique to the user in that case either, same as the other non-preserved
        // outcomes.
        #expect(!SelfUpdater.shouldPreserveStagingRoot(after: .backupFailed))
        #expect(!SelfUpdater.shouldPreserveStagingRoot(after: nil))
    }

    // MARK: stagingHasPreservedBackup (Finding 3 — destroying a preserved rollback-failure backup)

    /// Reproduces the actual bug: a REAL directory at `stagingRoot/backup.app` (exactly what a
    /// prior `.rollbackFailed` leaves behind — see `SelfUpdateInstallerTests`) must be detected
    /// so `runUpdate` can refuse to wipe it, not a hand-invented boolean.
    @Test func stagingHasPreservedBackupIsTrueWhenABackupAppDirectoryExists() throws {
        let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: stagingRoot.appendingPathComponent("backup.app/Contents/MacOS"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        #expect(SelfUpdater.stagingHasPreservedBackup(stagingRoot: stagingRoot))
    }

    /// The common case — no staging directory at all (first update ever, or a prior update that
    /// cleaned up normally) — must never be treated as a preserved backup.
    @Test func stagingHasPreservedBackupIsFalseWhenStagingDoesNotExist() {
        let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(!SelfUpdater.stagingHasPreservedBackup(stagingRoot: stagingRoot))
    }

    /// A staging directory can legitimately exist without a preserved backup inside it (e.g. a
    /// download/verification failure that hasn't been cleaned up yet for some other reason) —
    /// only the presence of `backup.app` itself must trigger the refusal.
    @Test func stagingHasPreservedBackupIsFalseWhenStagingExistsWithoutABackup() throws {
        let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stagingRoot.appendingPathComponent("extracted"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        #expect(!SelfUpdater.stagingHasPreservedBackup(stagingRoot: stagingRoot))
    }

    /// Full-path regression test through the actual public entry point (`performUpdate`, not
    /// just the pure `stagingHasPreservedBackup` helper): reproduces a REAL preserved backup on
    /// disk exactly where a previous `.rollbackFailed` would have left one, then confirms
    /// `runUpdate` refuses BEFORE ever touching the network — no `URLSession` mocking needed,
    /// since this must be the very first thing checked, ahead of the old unconditional
    /// `removeItem(at: stagingRoot)`. A revert that dropped the guard (while leaving
    /// `stagingHasPreservedBackup` itself intact and passing its own unit tests above) would
    /// only be caught by an integration-level test like this one: it would delete the backup
    /// directory as its very next step, so the final assertion below would fail.
    @Test func performUpdateRefusesAndPreservesABackupLeftByAPreviousRollbackFailure() async throws {
        let installedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: installedRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: installedRoot) }
        let installedBundlePath = installedRoot.appendingPathComponent("FreeTalker.app")
        let backupPath = installedRoot.appendingPathComponent(".freetalker-update/backup.app")
        let backupBinary = backupPath.appendingPathComponent("Contents/MacOS/FreeTalker")
        try FileManager.default.createDirectory(at: backupBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("preserved backup binary".utf8).write(to: backupBinary)

        let manifest = UpdateManifest(
            version: "v99.0.0", assetURL: URL(string: "https://example.invalid/never-reached.zip")!,
            sha256: "unused", signature: "unused"
        )
        let outcome = await SelfUpdater.performUpdate(manifest: manifest, installedBundlePath: installedBundlePath, session: .shared)

        guard case .failed(let message) = outcome else {
            Issue.record("expected .failed (refusing to proceed), got \(outcome)")
            return
        }
        #expect(message.contains(backupPath.path))
        // The property that actually matters: the preserved backup must survive untouched.
        #expect(FileManager.default.fileExists(atPath: backupBinary.path))
    }

    // MARK: makeInvocationStagingRoot / concurrent-update isolation (Round-3 Finding 1)

    /// The core isolation property the fix depends on: two invocations must never compute the
    /// same staging path. `UUID()`-based, but asserted directly rather than assumed — if this
    /// ever started returning a fixed/predictable name (the exact shape of the original bug,
    /// where every invocation shared `.freetalker-update/update.zip`), this is what would catch
    /// it.
    @Test func makeInvocationStagingRootIsUniquePerCall() {
        let updateRoot = URL(fileURLWithPath: "/Applications/.freetalker-update", isDirectory: true)
        let first = SelfUpdater.makeInvocationStagingRoot(updateRoot: updateRoot)
        let second = SelfUpdater.makeInvocationStagingRoot(updateRoot: updateRoot)
        #expect(first != second)
        #expect(first.deletingLastPathComponent() == updateRoot)
        #expect(second.deletingLastPathComponent() == updateRoot)
    }

    /// Blocks `startLoading()` until the test explicitly releases it, so a test can GUARANTEE two
    /// `performUpdate` calls are genuinely overlapping in time — not hoping a wall-clock race
    /// lines up — before asserting what happens when a second one starts while the first is still
    /// mid-download. This is exactly the "call B starts... stalls" shape from the finding.
    private final class StallingURLProtocol: URLProtocol, @unchecked Sendable {
        static let requestStarted = DispatchSemaphore(value: 0)
        static let releaseResponse = DispatchSemaphore(value: 0)

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requestStarted.signal()
            Self.releaseResponse.wait()
            guard let url = request.url, let client else { return }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data("not a real signed zip — only used to prove the gate rejects overlap".utf8))
            client.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        // Plain (non-`async`) wrappers around the semaphore waits: `DispatchSemaphore.wait()`
        // is `@available(*, noasync)` — calling it directly from an `async` test body is a
        // compile error (it would block a cooperative-pool thread). Routing through an ordinary
        // synchronous function sidesteps that while keeping the actual blocking-wait behavior
        // this test needs to guarantee real overlap between the two calls.
        static func blockUntilRequestStarted() { requestStarted.wait() }
        static func releaseTheBlockedResponse() { releaseResponse.signal() }
    }

    /// Reproduces the exact concurrency shape of Round-3 Finding 1: call A is genuinely mid-flight
    /// (blocked on the network, past the point where a shared `update.zip` would already have
    /// been created under the OLD code) when call B starts against the SAME installed bundle.
    /// Demonstrates the fix concretely: B is rejected by `SelfUpdater`'s in-process gate
    /// IMMEDIATELY — before it can create a staging directory, write anything, or observe A's
    /// path at all — and A completing afterward is unaffected by B having been attempted. A
    /// revert that dropped `UpdateInProgressGate` (while leaving per-invocation staging in place)
    /// would fail this test: B would proceed to create its OWN staging directory instead of being
    /// rejected, so `secondReason.contains("already in progress")` would fail.
    @Test func secondConcurrentUpdateIsRejectedWhileFirstIsInFlightRatherThanRacingItsStagingPath() async throws {
        let installedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: installedRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: installedRoot) }
        let installedBundlePath = installedRoot.appendingPathComponent("FreeTalker.app")

        let manifest = UpdateManifest(
            version: "v99.0.0", assetURL: URL(string: "https://stalling.freetalker.invalid/update.zip")!,
            sha256: "unused", signature: "unused"
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StallingURLProtocol.self]
        let session = URLSession(configuration: config)

        async let firstOutcome = SelfUpdater.performUpdate(
            manifest: manifest, installedBundlePath: installedBundlePath, session: session
        )

        // Block until call A has genuinely reached the network — guarantees real overlap rather
        // than a timing-dependent race.
        StallingURLProtocol.blockUntilRequestStarted()

        let secondOutcome = await SelfUpdater.performUpdate(
            manifest: manifest, installedBundlePath: installedBundlePath, session: session
        )
        guard case .failed(let secondReason) = secondOutcome else {
            Issue.record("expected the second concurrent call to fail, got \(secondOutcome)")
            StallingURLProtocol.releaseTheBlockedResponse()
            _ = await firstOutcome
            return
        }
        #expect(secondReason.contains("already in progress"))

        // Let call A proceed — it fails later for an unrelated reason (bogus checksum, since this
        // test never constructs a real signed zip), which is irrelevant here: the property under
        // test is that B never got to run AT ALL while A held the gate, not what became of A.
        StallingURLProtocol.releaseResponse.signal()
        let resolvedFirst = await firstOutcome
        guard case .failed(let firstReason) = resolvedFirst else {
            Issue.record("expected call A to also fail (bogus checksum), got \(resolvedFirst)")
            return
        }
        #expect(!firstReason.contains("already in progress"))
        // And the gate is released again afterward — a THIRD call isn't permanently wedged by
        // the two above.
        let thirdOutcome = await SelfUpdater.performUpdate(
            manifest: manifest, installedBundlePath: installedBundlePath, session: .shared
        )
        guard case .failed(let thirdReason) = thirdOutcome else {
            Issue.record("expected the third call to also fail (unreachable host), got \(thirdOutcome)")
            return
        }
        #expect(!thirdReason.contains("already in progress"))
    }

    // MARK: elevatePreservedBackup (Round-3 Finding 2 — a successful update wedging the next one)

    /// The genuine-rollback-failure path: `elevatePreservedBackup` must move the per-invocation
    /// working backup to the canonical location `stagingHasPreservedBackup` checks, so it stays
    /// discoverable across process relaunches. This is the EXACT function `runUpdate` calls on
    /// `.rollbackFailed` — not a re-derived stand-in.
    @Test func elevatePreservedBackupMovesTheWorkingBackupToTheCanonicalLocationAndMakesItDiscoverable() throws {
        let updateRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: updateRoot) }
        let workingBackupPath = updateRoot.appendingPathComponent("run-\(UUID().uuidString)/backup.app")
        let backupBinary = workingBackupPath.appendingPathComponent("Contents/MacOS/FreeTalker")
        try FileManager.default.createDirectory(at: backupBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("genuine previous app".utf8).write(to: backupBinary)
        let canonicalBackupPath = updateRoot.appendingPathComponent("backup.app")

        #expect(SelfUpdater.elevatePreservedBackup(from: workingBackupPath, to: canonicalBackupPath))
        #expect(!FileManager.default.fileExists(atPath: workingBackupPath.path))
        #expect(FileManager.default.fileExists(atPath: canonicalBackupPath.appendingPathComponent("Contents/MacOS/FreeTalker").path))
        // Discoverable across a relaunch the same way a genuine `.rollbackFailed` backup must be.
        #expect(SelfUpdater.stagingHasPreservedBackup(stagingRoot: updateRoot))
    }

    /// Fails closed rather than crashing when there's nothing to elevate — defensive, but matters
    /// because this runs on the failure path of an already-failing update.
    @Test func elevatePreservedBackupFailsClosedWhenTheSourceIsMissing() {
        let updateRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let missingSource = updateRoot.appendingPathComponent("run-\(UUID().uuidString)/backup.app")
        let canonicalBackupPath = updateRoot.appendingPathComponent("backup.app")
        #expect(!SelfUpdater.elevatePreservedBackup(from: missingSource, to: canonicalBackupPath))
    }

    /// Reproduces Round-3 Finding 2 directly: leftover junk from a swallowed cleanup failure
    /// after a SUCCESSFUL update sits inside a per-invocation `run-*` directory — NEVER at the
    /// canonical `backup.app` path, because `elevatePreservedBackup` (the ONLY thing that ever
    /// populates the canonical path) is called ONLY on `.rollbackFailed`. A verifier that let
    /// success-path leftovers reach the canonical name would fail this test: it would see
    /// `stagingHasPreservedBackup` report `true` for stray junk from a HEALTHY install, wedging
    /// every future update exactly the way the finding describes.
    @Test func leftoverJunkInsideAPerInvocationDirectoryNeverWedgesFutureUpdates() throws {
        let updateRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: updateRoot) }
        let leftoverJunk = updateRoot.appendingPathComponent("run-\(UUID().uuidString)/backup.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: leftoverJunk, withIntermediateDirectories: true)

        #expect(!SelfUpdater.stagingHasPreservedBackup(stagingRoot: updateRoot))
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

    /// The real `dist/latest.json` shape produced by `scripts/release.sh v0.1.0 --dry-run` —
    /// not hand-invented, this is exactly what the release script writes, `signature` field
    /// included.
    @Test func decodesTheManifestJSONShapeReleaseScriptWrites() throws {
        let json = """
        {
          "version": "v0.1.0",
          "assetURL": "https://github.com/bruno-rv/freetalker/releases/download/v0.1.0/FreeTalker-v0.1.0.app.zip",
          "sha256": "c1fc1ebc8e3d3c5194243090ac0f0207f62f880b38ad585d3320a36d1b49f9e7",
          "signature": "R95Iu4vvA7NBlaErnOzHLxRSv4ivw9j1ayzwPVort9bjanHbqUfN/7uqZxEQ3Ju4c2TeKsdpl4LiJ+cMA/gRDQ=="
        }
        """
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        #expect(manifest.version == "v0.1.0")
        #expect(
            manifest.assetURL.absoluteString
                == "https://github.com/bruno-rv/freetalker/releases/download/v0.1.0/FreeTalker-v0.1.0.app.zip"
        )
        #expect(manifest.sha256 == "c1fc1ebc8e3d3c5194243090ac0f0207f62f880b38ad585d3320a36d1b49f9e7")
        #expect(manifest.signature == "R95Iu4vvA7NBlaErnOzHLxRSv4ivw9j1ayzwPVort9bjanHbqUfN/7uqZxEQ3Ju4c2TeKsdpl4LiJ+cMA/gRDQ==")
    }

    /// A manifest published before this feature (or by a broken release) with no `signature`
    /// field at all must still decode — `SelfUpdater`/`UpdateSignatureVerifier` are what turn a
    /// missing signature into a specific, legible failure (`.missingSignature`), not a generic
    /// JSON decode error that would be indistinguishable from a truncated/corrupt manifest.
    @Test func decodesAManifestWithNoSignatureFieldAsNilRatherThanFailing() throws {
        let json = """
        {
          "version": "v0.1.0",
          "assetURL": "https://github.com/bruno-rv/freetalker/releases/download/v0.1.0/FreeTalker-v0.1.0.app.zip",
          "sha256": "c1fc1ebc8e3d3c5194243090ac0f0207f62f880b38ad585d3320a36d1b49f9e7"
        }
        """
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        #expect(manifest.signature == nil)
    }

    // MARK: runProcess bounded read (Finding 8 — a descendant inheriting stdout defeats the timeout)

    /// Reproduces Finding 8 exactly: the CHILD forks a descendant (`sleep 5 &`) that inherits the
    /// stdout pipe and then the child itself exits immediately (`exit 0`). `waitUntilExit()` on
    /// the direct child returns promptly either way — the bug was that the OLD code's
    /// `readDataToEndOfFile()` call, made before `waitUntilExit()`, stayed blocked waiting for
    /// the pipe's write end to close, which only happens when the still-running descendant
    /// exits ~5s later. `timeout`/`killGracePeriod` here are both short specifically so the
    /// assertion below distinguishes "bounded by the read deadline" from "bounded by the
    /// descendant's own 5s sleep" with a wide margin.
    @Test func runProcessReturnsPromptlyWhenAForkedDescendantInheritsStdoutAndOutlivesTheChild() {
        let start = Date()
        let result = SelfUpdater.runProcess("/bin/sh", ["-c", "sleep 5 & exit 0"], timeout: 0.3, killGracePeriod: 0.3)
        let elapsed = Date().timeIntervalSince(start)
        #expect(result.status == 0)
        #expect(elapsed < 2, "runProcess took \(elapsed)s — a descendant holding stdout open defeated the read bound")
    }
}
