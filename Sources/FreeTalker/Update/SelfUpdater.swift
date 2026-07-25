import AppKit
import CryptoKit
import Foundation

/// Downloads a newer signed release, verifies it end-to-end, and swaps it into the install
/// location — replacing the old git-pull-and-rebuild path.
///
/// **Root cause of the bug this replaces:** the previous `SelfUpdater` resolved the running
/// bundle's parent directory (`Bundle.main.bundleURL.deletingLastPathComponent()`) and required
/// it to be a git working tree (`git rev-parse --show-toplevel`). That held only while
/// `FreeTalker.app` lived inside its own source clone. Once the `Makefile`'s `install` target
/// made `/Applications` the canonical install location, the bundle's parent became
/// `/Applications` — not a git repo — so every check failed with "app not running from its
/// repo." Self-update was broken for the app anyone actually runs.
///
/// Every step below fails closed: any verification failure or swap failure leaves the
/// currently-installed app exactly as it was (see `SelfUpdateInstaller`).
enum SelfUpdater {
    enum Availability: Equatable {
        case upToDate
        case available(manifest: UpdateManifest)
        case unavailable(String)
    }

    struct CheckReport: Equatable {
        let availability: Availability
        let currentVersion: String
    }

    enum UpdateOutcome: Equatable {
        case success
        case failed(String)
    }

    /// Whether a swap's working backup — see `elevatePreservedBackup` — must be rescued out of
    /// the per-invocation staging directory before that directory is deleted. Pure and
    /// independently testable: the one case that must answer `true` is `.rollbackFailed`, where
    /// `SelfUpdateInstaller.swap` already backed up the original app but couldn't put it back.
    /// Every other outcome (including "no swap was attempted at all" — `nil`, e.g. a
    /// download/verification failure) is safe to clean up as part of ordinary per-invocation
    /// staging cleanup, because nothing that survives only in staging is unique to the user in
    /// those cases.
    static func shouldPreserveStagingRoot(after result: SelfUpdateInstaller.SwapResult?) -> Bool {
        result == .rollbackFailed
    }

    enum StagedVersionCheck: Equatable {
        case ok
        case unreadable
        case mismatchedManifest(staged: String, claimed: String)
        case notNewer(staged: SemanticVersion, current: SemanticVersion)
    }

    /// Binds the manifest's claimed version to what's actually inside the signed, checksummed
    /// artifact, and to the version currently running. Without this, `evaluate(current:
    /// manifest:)` above only ever looks at the manifest's *claim* — a manifest claiming
    /// v999.0.0 while its `assetURL` still points at the signed ZIP for v1.0.0 would pass
    /// `evaluate` and then install that old artifact anyway; replaying the currently-installed
    /// ZIP under a fabricated newer version number would create a permanent "update available"
    /// loop that can never actually resolve, since the stamped version never reaches the
    /// claimed one. Pure and independently testable without touching the filesystem/network.
    static func validateStagedVersion(
        stagedVersionString: String?, manifestVersion: String, currentVersion: SemanticVersion
    ) -> StagedVersionCheck {
        guard let stagedVersionString, let staged = SemanticVersion(string: stagedVersionString) else {
            return .unreadable
        }
        guard let claimed = SemanticVersion(string: manifestVersion), staged == claimed else {
            return .mismatchedManifest(staged: stagedVersionString, claimed: manifestVersion)
        }
        guard staged > currentVersion else {
            return .notNewer(staged: staged, current: currentVersion)
        }
        return .ok
    }

    /// GitHub always resolves `.../releases/latest/download/<name>` to the matching asset on
    /// the most recently published (non-draft, non-prerelease) release — a stable URL that
    /// doesn't need to know the tag name in advance. Published by `scripts/release.sh`.
    static let manifestURL = URL(string: "https://github.com/bruno-rv/freetalker/releases/latest/download/latest.json")!

    // MARK: Pure decision logic (unit-tested without any network/process access)

    static func evaluate(current: SemanticVersion, manifest: UpdateManifest) -> Availability {
        guard let latest = SemanticVersion(string: manifest.version) else {
            return .unavailable("Could not parse the published release version.")
        }
        guard latest > current else { return .upToDate }
        return .available(manifest: manifest)
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Check

    static func check(session: URLSession = .shared) async -> CheckReport {
        let currentVersion = AppVersion.currentString
        do {
            let (data, response) = try await session.data(from: manifestURL)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return CheckReport(
                    availability: .unavailable("Could not reach the release server."),
                    currentVersion: currentVersion
                )
            }
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
            return CheckReport(
                availability: evaluate(current: AppVersion.current, manifest: manifest),
                currentVersion: currentVersion
            )
        } catch {
            return CheckReport(
                availability: .unavailable("Could not check for updates."),
                currentVersion: currentVersion
            )
        }
    }

    // MARK: Download, verify, swap

    /// Runs entirely off the main actor; safe to `await` from UI code. Stages the download in a
    /// hidden directory right next to `installedBundlePath` (not `/tmp`) so the final swap is a
    /// same-volume, near-atomic `rename(2)` — see `SelfUpdateInstaller`.
    static func performUpdate(
        manifest: UpdateManifest,
        installedBundlePath: URL = URL(fileURLWithPath: Bundle.main.bundlePath),
        session: URLSession = .shared
    ) async -> UpdateOutcome {
        await Task.detached(priority: .userInitiated) {
            await Self.runUpdate(manifest: manifest, installedBundlePath: installedBundlePath, session: session)
        }.value
    }

    /// True when a PRIOR update attempt left the user's original app preserved at
    /// `updateRoot/backup.app` — the ONE canonical, fixed location, shared by every invocation
    /// past and future — because `SelfUpdateInstaller.swap` backed it up but then failed to
    /// restore it (`.rollbackFailed` — see `shouldPreserveStagingRoot`/`elevatePreservedBackup`).
    /// That backup is the user's ONLY surviving copy of their previous app in that state. Checked
    /// against the filesystem directly (not any in-memory result, which doesn't survive a
    /// relaunch) so it catches a backup left by a PREVIOUS run of the app, not just this one —
    /// `runUpdate` must refuse to proceed while this is true.
    static func stagingHasPreservedBackup(stagingRoot updateRoot: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: updateRoot.appendingPathComponent("backup.app").path)
    }

    /// Builds a fresh, unpredictable-to-nobody-but-this-call staging directory under
    /// `updateRoot` for ONE invocation of `runUpdate`. Pulled out as its own pure function
    /// (rather than inlined) so it's directly testable: the property that matters is that two
    /// calls never collide, which `SelfUpdaterTests` verifies without needing to run two real
    /// updates concurrently. `UUID()` gives that uniqueness the same way it does everywhere else
    /// in this codebase that needs an unguessable, collision-free name.
    ///
    /// This is the isolation half of the fix for the concurrent-update finding: `update.zip`,
    /// `extracted/`, and the in-flight working backup all end up nested under this per-call
    /// directory, so a second invocation — even one racing the first — can never write to, or
    /// read from, the same path the first is verifying and unpacking.
    static func makeInvocationStagingRoot(updateRoot: URL) -> URL {
        updateRoot.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
    }

    /// Moves a swap's in-flight working backup (private to one `runUpdate` invocation, see
    /// `makeInvocationStagingRoot`) into the ONE canonical, cross-relaunch-discoverable location
    /// `stagingHasPreservedBackup` checks. Called ONLY when `SelfUpdateInstaller.swap` reports
    /// `.rollbackFailed` — i.e. only when this content is genuinely the user's sole surviving
    /// copy of their previous app, never on a successful update. That discipline is what keeps
    /// `backupPath`'s mere existence trustworthy: a caller can act on "this backup exists" as
    /// "you must recover this" without also having to ask "or is this just leftover junk from a
    /// healthy install?" — the two can no longer be confused, because a healthy install's
    /// leftover junk (if any) never gets moved here in the first place; see `runUpdate`.
    static func elevatePreservedBackup(from workingBackupPath: URL, to backupPath: URL, fileManager: FileManager = .default) -> Bool {
        do {
            try fileManager.createDirectory(at: backupPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: workingBackupPath, to: backupPath)
            return true
        } catch {
            return false
        }
    }

    /// Ensures at most one `runUpdate` body executes at a time. Necessary IN ADDITION to the
    /// per-invocation staging isolation above, not instead of it: `SelfUpdateInstaller.swap`
    /// mutates `installedBundlePath` itself — a single resource shared by every invocation no
    /// matter how private each one's own staging directory is. Two concurrent swaps racing to
    /// move the same live install out from under each other (or a second invocation deleting a
    /// backup a slower one just preserved at the canonical `backupPath`) are both races on that
    /// SHARED state, which private staging alone does nothing to prevent. In-process (an
    /// `NSLock`-guarded flag, same pattern as `LockedOutputBuffer`/`KillEscalationCancelToken`
    /// below) is sufficient because `FreeTalker` only ever runs as a single instance — see
    /// whatever enforces that single-instance lease elsewhere in the app.
    private final class UpdateInProgressGate: @unchecked Sendable {
        private let lock = NSLock()
        private var inProgress = false

        /// Atomically claims the gate; `false` means another update is already running and
        /// nothing was claimed.
        func begin() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !inProgress else { return false }
            inProgress = true
            return true
        }

        func end() {
            lock.lock()
            inProgress = false
            lock.unlock()
        }
    }

    private static let updateGate = UpdateInProgressGate()

    private static func runUpdate(
        manifest: UpdateManifest, installedBundlePath: URL, session: URLSession
    ) async -> UpdateOutcome {
        // Claimed FIRST, before any filesystem or network access, so a second concurrent call
        // fails fast rather than racing the first through download/verify/swap. See
        // `UpdateInProgressGate`'s doc comment for why staging isolation alone can't replace
        // this.
        guard Self.updateGate.begin() else {
            return .failed("An update is already in progress — try again once it finishes.")
        }
        defer { Self.updateGate.end() }

        let fileManager = FileManager.default
        let updateRoot = installedBundlePath.deletingLastPathComponent()
            .appendingPathComponent(".freetalker-update", isDirectory: true)
        // The ONE canonical, fixed location a preserved rollback-failure backup can ever live —
        // NOT per-invocation, so it stays discoverable across process relaunches (a backup left
        // by a previous run of the app must still block this one). Populated ONLY via
        // `elevatePreservedBackup` below, and ONLY on `.rollbackFailed` — never by a successful
        // update, whose own working backup lives and dies inside that invocation's private
        // `stagingRoot` instead. See `elevatePreservedBackup`'s doc comment for why that
        // discipline matters.
        let backupPath = updateRoot.appendingPathComponent("backup.app")

        // A preserved backup from a previous failed update is the user's only surviving copy of
        // their previous app — refuse to proceed until it's been recovered manually. Checked
        // against `updateRoot`, not any per-invocation staging directory, so it catches a backup
        // left by a PREVIOUS run of the app.
        guard !Self.stagingHasPreservedBackup(stagingRoot: updateRoot, fileManager: fileManager) else {
            return .failed(
                "A previous update couldn't restore your prior app automatically, and it's still "
                    + "preserved at \(backupPath.path). Move it to \(installedBundlePath.path) "
                    + "manually, then try updating again — this won't proceed while that backup "
                    + "is there, to avoid deleting your only remaining copy."
            )
        }

        // Private to THIS invocation — see `makeInvocationStagingRoot`. `update.zip`,
        // `extracted/`, and the working backup used during this invocation's swap all live
        // here, under a name no other invocation (past, concurrent, or future) ever knows or
        // reuses, so nothing can overwrite bytes this invocation has already verified.
        let stagingRoot = Self.makeInvocationStagingRoot(updateRoot: updateRoot)
        do {
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        } catch {
            return .failed("Could not create a staging directory next to the installed app.")
        }
        let workingBackupPath = stagingRoot.appendingPathComponent("backup.app")
        // Whether it's safe to delete this invocation's ENTIRE private `stagingRoot` once the
        // attempt finishes. Starts `true` (the common case: nothing in a private, per-invocation
        // directory is ever unique to the user) and is flipped to `false` only in the narrow
        // window between a `.rollbackFailed` swap and a successful `elevatePreservedBackup` —
        // i.e. only while `workingBackupPath`, still inside `stagingRoot`, is the user's sole
        // surviving copy of their previous app and hasn't yet been rescued out to the canonical
        // `backupPath`.
        var stagingRootSafeToDelete = true
        defer {
            if stagingRootSafeToDelete {
                try? fileManager.removeItem(at: stagingRoot)
            }
        }

        // 0. The public key compiled into THIS binary is the trust anchor for every update —
        // resolve it first and fail closed immediately if it's missing, before any network
        // access. Can only happen if scripts/make-release-signing-key.sh was never run for this
        // build (see UpdatePublicKey.swift) — unlike the certificate-fingerprint pin this
        // replaces, this has no dependency on codesign identity or machine-local keychain trust
        // at all, so an ad-hoc (`-s -`) build can still verify updates fine as long as the
        // public key is compiled in.
        guard let publicKey = UpdatePublicKey.current else {
            return .failed(
                "This build has no release-signing public key compiled in, so it can never "
                    + "verify a downloaded update. See scripts/make-release-signing-key.sh."
            )
        }

        // 1. Download.
        let zipPath = stagingRoot.appendingPathComponent("update.zip")
        let downloadedData: Data
        do {
            let (data, response) = try await session.data(from: manifest.assetURL)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return .failed("Download failed (bad response from the release server).")
            }
            downloadedData = data
            try data.write(to: zipPath)
        } catch {
            return .failed("Download failed: \(error.localizedDescription)")
        }

        // 2. Integrity: published checksum. This is a CORRUPTION check only, not authenticity —
        // the manifest comes from the same host as the release, so a compromised host could
        // publish a matching checksum for tampered bytes just as easily as the real ones. Step 3
        // below (the Ed25519 signature) is the actual trust boundary.
        guard sha256Hex(of: downloadedData).caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
            return .failed("The downloaded file's checksum didn't match the published release — discarded.")
        }

        // 3. Authenticity: verify the detached Ed25519 signature over the raw downloaded bytes,
        // BEFORE anything is unzipped or executed — this is the actual security boundary for
        // self-update. The trust anchor is `publicKey`, compiled into THIS binary; it never
        // depends on anything fetched over the network (including this manifest) or on any
        // machine's local codesign/keychain trust.
        switch UpdateSignatureVerifier.verify(data: downloadedData, signatureBase64: manifest.signature, publicKey: publicKey) {
        case .valid:
            break
        case .missingSignature, .invalidEncoding:
            return .failed("The published release has no valid signature — refusing to install it.")
        case .mismatch:
            return .failed("The downloaded update's signature didn't verify — refusing to install it.")
        }

        // 4. Unzip (ditto preserves the code signature's resource fork / extended attributes;
        // `unzip` does not).
        let extractedRoot = stagingRoot.appendingPathComponent("extracted", isDirectory: true)
        guard runProcess("/usr/bin/ditto", ["-x", "-k", zipPath.path, extractedRoot.path]).status == 0 else {
            return .failed("Could not unpack the downloaded update.")
        }
        // Defense in depth even though step 3 already authenticated these exact bytes: a ZIP
        // whose top-level `.app` entry (or anything nested inside it) is a symlink survives
        // `ditto` intact. If that symlink pointed at, say, `/Applications/FreeTalker.app`
        // itself, the smoke test below would transparently follow it and launch the CURRENTLY
        // INSTALLED app instead of what was actually staged, and `SelfUpdateInstaller.swap`
        // would promote the self-referential symlink into place, destroying the install. A real
        // release built by `scripts/release.sh`/`make bundle` never contains a symlink anywhere
        // (confirmed: `find FreeTalker.app -type l` is always empty for this app), so this can't
        // reject a legitimate update.
        guard !Self.containsSymlink(at: extractedRoot, fileManager: fileManager) else {
            return .failed("The downloaded update contained a symbolic link — refusing to install it.")
        }
        guard
            let contents = try? fileManager.contentsOfDirectory(at: extractedRoot, includingPropertiesForKeys: [.isDirectoryKey]),
            let stagedBundle = contents.first(where: { $0.pathExtension == "app" }),
            (try? stagedBundle.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        else {
            return .failed("The downloaded update didn't contain an app bundle.")
        }

        // 5. Version binding: the staged bundle's OWN stamped version (`Makefile`'s
        // `plutil -replace CFBundleShortVersionString`) must match what the manifest claims AND
        // be strictly newer than what's currently running — `evaluate(current:manifest:)` above
        // only ever looked at the manifest's *claim*, and step 3's signature only authenticates
        // the asset bytes, not the version number in the manifest JSON next to it. Without this,
        // a manifest claiming an inflated version (say v999.0.0) whose `assetURL`/`signature`
        // still point at an old, validly-signed ZIP would install that old artifact anyway, and
        // replaying the currently-installed ZIP under a fabricated version number would create a
        // permanent "update available" loop.
        let stagedVersionString = Bundle(url: stagedBundle)?.infoDictionary?["CFBundleShortVersionString"] as? String
        switch Self.validateStagedVersion(
            stagedVersionString: stagedVersionString, manifestVersion: manifest.version, currentVersion: AppVersion.current
        ) {
        case .ok:
            break
        case .unreadable:
            return .failed("The downloaded update's bundle didn't report a valid version — refusing to install it.")
        case .mismatchedManifest:
            return .failed("The downloaded update's stamped version didn't match the published manifest — refusing to install it.")
        case .notNewer:
            return .failed("The downloaded update isn't newer than the version currently running — refusing to install it.")
        }

        // 6. Smoke test: the staged binary actually starts (catches a corrupt build or an
        // architecture/framework mismatch before it ever touches the installed app).
        guard verifyLaunches(bundlePath: stagedBundle.path) else {
            return .failed("The downloaded update failed to start — refusing to install it.")
        }

        // 7. Atomic swap with rollback. `backupPath` here is `workingBackupPath` — private to
        // THIS invocation — never the canonical, fixed `backupPath` above; see
        // `elevatePreservedBackup`.
        let result = SelfUpdateInstaller.swap(
            installedPath: installedBundlePath,
            stagedPath: stagedBundle,
            backupPath: workingBackupPath,
            ops: SelfUpdateInstaller.FileOps(
                moveItem: { try fileManager.moveItem(at: $0, to: $1) },
                removeItem: { try fileManager.removeItem(at: $0) },
                fileExists: { fileManager.fileExists(atPath: $0.path) }
            )
        )
        switch result {
        case .success:
            return .success
        case .rolledBack:
            return .failed("The update couldn't be installed — your previous version is unchanged.")
        case .rollbackFailed:
            // The user's only surviving copy of their previous app is at `workingBackupPath`,
            // still inside this invocation's private `stagingRoot` — rescue it to the canonical,
            // cross-relaunch-discoverable `backupPath` BEFORE the `defer` above can delete
            // `stagingRoot`. See `shouldPreserveStagingRoot`/`elevatePreservedBackup`.
            if Self.shouldPreserveStagingRoot(after: result),
                Self.elevatePreservedBackup(from: workingBackupPath, to: backupPath, fileManager: fileManager)
            {
                return .failed(
                    "The update failed partway and your previous app couldn't be restored automatically. "
                        + "It's preserved at \(backupPath.path) — move it to \(installedBundlePath.path) manually."
                )
            }
            // Elevation itself failed (e.g. couldn't create `updateRoot`) — the backup is still
            // only reachable at `workingBackupPath`. Must not let the `defer` above delete it:
            // report its ACTUAL location rather than claiming it's at `backupPath`, which would
            // be false.
            stagingRootSafeToDelete = false
            return .failed(
                "The update failed partway and your previous app couldn't be restored automatically. "
                    + "It's preserved at \(workingBackupPath.path) — move it to \(installedBundlePath.path) manually."
            )
        case .backupFailed:
            return .failed(
                "Could not back up the currently installed app before updating — nothing was "
                    + "moved. Your existing installation at \(installedBundlePath.path) is untouched."
            )
        }
    }

    /// True if `root`, or anything inside it at any depth, is a symbolic link. See the doc
    /// comment at its call site in `runUpdate` for why this exists.
    static func containsSymlink(at root: URL, fileManager: FileManager = .default) -> Bool {
        guard let rootValues = try? root.resourceValues(forKeys: [.isSymbolicLinkKey]) else { return false }
        if rootValues.isSymbolicLink == true { return true }
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            return false
        }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                return true
            }
        }
        return false
    }

    /// Launches the staged binary with `--verify-launch`, which exits immediately (see
    /// `FreeTalkerApp.init`) before touching TCC, the single-instance lease, or any user state.
    /// A crash (missing/incompatible framework, corrupt binary) reports a non-zero/aborted
    /// status just as reliably as an explicit failure would.
    private static func verifyLaunches(bundlePath: String, timeout: TimeInterval = 10) -> Bool {
        let executable = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/MacOS/FreeTalker")
        return runProcess(executable.path, ["--verify-launch"], timeout: timeout).status == 0
    }

    /// `killGracePeriod` bounds the OVERALL wait: `SIGTERM` alone isn't a hard bound (a hung or
    /// deliberately misbehaving child can ignore it indefinitely). `SIGKILL` cannot be caught or
    /// ignored, so escalating to it after `killGracePeriod` guarantees the CHILD PROCESS itself
    /// exits within `timeout + killGracePeriod`. The escalation runs on its own dedicated
    /// `Thread` rather than `DispatchQueue.global()`'s shared worker pool specifically so that
    /// this bound holds even when that pool is saturated by unrelated blocking work elsewhere in
    /// the process (e.g. many other `runProcess` calls in flight) — a shared-queue timer can be
    /// starved behind that backlog, a dedicated thread cannot. Not `private` so
    /// `SelfUpdaterTests` can exercise the escalation directly against a real child process that
    /// ignores `SIGTERM`.
    static func runProcess(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = 30, killGracePeriod: TimeInterval = 2
    ) -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let terminateWorkItem = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: terminateWorkItem)
        // Deliberately unconditional — no `process.isRunning` guard. `isRunning` can go stale
        // (report `false`) once `terminate()` has been called even though the child ignored
        // `SIGTERM` and is still very much alive, which would silently skip the kill this exists
        // to guarantee. `kill(2)` on an already-exited PID just returns `ESRCH`, which is safe
        // to ignore — nothing here needs its return value. Runs on a dedicated thread (see the
        // doc comment above) instead of `DispatchQueue.global().asyncAfter`, which is what
        // actually made the bound unreliable: under a saturated global queue the timer block
        // itself can't get a worker thread in time.
        let killCancelled = KillEscalationCancelToken()
        let pid = process.processIdentifier
        let killThread = Thread {
            Thread.sleep(forTimeInterval: timeout + killGracePeriod)
            if !killCancelled.isCancelled {
                kill(pid, SIGKILL)
            }
        }
        killThread.name = "SelfUpdater.runProcess.killEscalation"
        killThread.start()
        // Bound the READ itself, not just the process's own lifetime (Finding 8): both
        // `terminate()` and the `SIGKILL` escalation above target only `pid`, the DIRECT child.
        // If that child forks a descendant that inherits the pipe's write end and outlives it
        // (e.g. `sh -c "sleep 30 & exit 0"`), the direct child exits promptly — `waitUntilExit`
        // returns fine — but the pipe is NOT at EOF, because the descendant still holds its own
        // copy of the write end open. The old code called the unbounded
        // `readDataToEndOfFile()` FIRST, so it stayed blocked waiting for that EOF no matter
        // what happened to `pid`, defeating both the timeout and the kill escalation entirely.
        // `readAvailableOutput` instead gives up waiting for more output after
        // `timeout + killGracePeriod` regardless of whether EOF ever arrives.
        let data = Self.readAvailableOutput(from: pipe, deadline: timeout + killGracePeriod)
        process.waitUntilExit()
        terminateWorkItem.cancel()
        killCancelled.cancel()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Reads whatever output arrives on `pipe` within `deadline`, then stops waiting — unlike
    /// `FileHandle.readDataToEndOfFile()`, this never blocks past `deadline` just because some
    /// process (not necessarily the one `runProcess` launched — see its doc comment) still holds
    /// the write end open. `readabilityHandler` schedules its callback via GCD only when data is
    /// actually available, so this doesn't itself dedicate a thread to blocking on the fd; the
    /// semaphore's `wait(timeout:)` is what makes the overall wait bounded regardless of whether
    /// the handler ever sees EOF (an empty read) before then.
    private static func readAvailableOutput(from pipe: Pipe, deadline: TimeInterval) -> Data {
        let fileHandle = pipe.fileHandleForReading
        let collected = LockedOutputBuffer()
        let doneSemaphore = DispatchSemaphore(value: 0)
        fileHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF: every writer, direct child or descendant, has closed its copy of the pipe.
                if collected.finish() { doneSemaphore.signal() }
            } else {
                collected.append(chunk)
            }
        }
        _ = doneSemaphore.wait(timeout: .now() + deadline)
        fileHandle.readabilityHandler = nil
        return collected.finishAndTakeData()
    }

    /// Backs `readAvailableOutput`'s accumulation with a lock instead of a captured `var`:
    /// `FileHandle.readabilityHandler`'s closure runs on a GCD-managed dispatch source, a
    /// different execution context than the caller reading the result afterward, and Swift 6's
    /// strict concurrency checking correctly refuses to let a plain captured `var` cross that
    /// boundary. `@unchecked Sendable` is safe here because every access is lock-guarded, same
    /// pattern as `KillEscalationCancelToken` below.
    private final class LockedOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var finished = false

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            data.append(chunk)
        }

        /// Marks the buffer finished; returns `true` only the first time (so the caller signals
        /// its semaphore exactly once even if more empty reads arrive afterward).
        func finish() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return false }
            finished = true
            return true
        }

        func finishAndTakeData() -> Data {
            lock.lock()
            defer { lock.unlock() }
            finished = true
            return data
        }
    }

    /// Lets `runProcess` suppress the kill thread's `SIGKILL` once the child has already exited
    /// on its own, without needing `DispatchWorkItem.cancel()` (which only applies to
    /// dispatch-queue-scheduled work, not a plain `Thread`).
    private final class KillEscalationCancelToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    // MARK: Relaunch

    /// The swap above replaces the bundle's contents in place at the same path — relaunching
    /// `Bundle.main.bundlePath` opens whatever is now there, i.e. the newly-installed version.
    @MainActor
    static func relaunchAfterUpdate(bundlePath: String = Bundle.main.bundlePath) {
        AppRelaunch.relaunch(bundlePath: bundlePath)
    }
}
