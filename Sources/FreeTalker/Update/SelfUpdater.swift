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

    /// Whether `runUpdate`'s staging directory (which, after a backup-then-promote swap, may be
    /// the ONLY place the user's previous app still exists — see `backupPath`) may be deleted
    /// once the update attempt finishes. Pure and independently testable: the one case that
    /// must answer `false` is `.rollbackFailed`, where `SelfUpdateInstaller.swap` already
    /// backed up the original app but couldn't put it back. Every other outcome (including
    /// "no swap was attempted at all" — `nil`, e.g. a download/verification failure) is safe to
    /// clean up, because nothing that survives only in staging is unique to the user in those
    /// cases.
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

    private static func runUpdate(
        manifest: UpdateManifest, installedBundlePath: URL, session: URLSession
    ) async -> UpdateOutcome {
        let fileManager = FileManager.default
        let stagingRoot = installedBundlePath.deletingLastPathComponent()
            .appendingPathComponent(".freetalker-update", isDirectory: true)
        try? fileManager.removeItem(at: stagingRoot)
        do {
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        } catch {
            return .failed("Could not create a staging directory next to the installed app.")
        }
        // `swapResult` is set only once a swap is actually attempted (step 6). Preserving
        // staging on `.rollbackFailed` matters because `backupPath` — the user's only surviving
        // copy of their previous app in that case — lives inside it; see
        // `shouldPreserveStagingRoot`.
        var swapResult: SelfUpdateInstaller.SwapResult?
        defer {
            if !Self.shouldPreserveStagingRoot(after: swapResult) {
                try? fileManager.removeItem(at: stagingRoot)
            }
        }

        // 0. The running app's own certificate fingerprint is the trust anchor for every check
        // below (see `CodeSignatureVerifier`'s doc comment) — resolve it first, and fail
        // closed immediately if there isn't one. An ad-hoc-signed running app (`codesign -s -`,
        // the default `make app` build) has no certificate to pin against at all, so it can
        // never verify a downloaded update no matter what that update contains — see README's
        // "Stable signing identity" section. Extracting this into its own explicit up-front
        // step (rather than letting it fall through to the generic mismatch message below) is
        // itself part of the fix for the ad-hoc self-comparison bug this guards against: it
        // means the running app's fingerprint is always resolved on its own, in its own fresh
        // extraction directory, before the downloaded bundle's fingerprint is ever computed.
        guard
            let runningFingerprintSHA1 = CodeSignatureVerifier.leafCertificateFingerprint(
                bundlePath: installedBundlePath.path, workingDirectory: stagingRoot, digest: "sha1"
            ),
            !runningFingerprintSHA1.isEmpty
        else {
            return .failed(
                "This copy of FreeTalker isn't signed with a stable identity, so it can never "
                    + "verify or install an update. See the README's \"Stable signing identity\" section."
            )
        }
        let runningFingerprint = CodeSignatureVerifier.leafCertificateFingerprint(
            bundlePath: installedBundlePath.path, workingDirectory: stagingRoot
        )

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

        // 2. Integrity: published checksum (transport corruption, not authenticity — see
        // UpdateManifest).
        guard sha256Hex(of: downloadedData).caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
            return .failed("The downloaded file's checksum didn't match the published release — discarded.")
        }

        // 3. Unzip (ditto preserves the code signature's resource fork / extended attributes;
        // `unzip` does not, and would break step 4 below).
        let extractedRoot = stagingRoot.appendingPathComponent("extracted", isDirectory: true)
        guard runProcess("/usr/bin/ditto", ["-x", "-k", zipPath.path, extractedRoot.path]).status == 0 else {
            return .failed("Could not unpack the downloaded update.")
        }
        // Reject a malicious archive before ever touching its contents with codesign/openssl/a
        // real launch: a ZIP whose top-level `.app` entry (or anything nested inside it) is a
        // symlink survives `ditto` intact. If that symlink pointed at, say,
        // `/Applications/FreeTalker.app` itself, every check below (codesign, cert extraction,
        // the smoke test) would transparently follow it and inspect the CURRENTLY INSTALLED
        // app instead of what was actually staged — passing every check while never having had
        // to defeat any of them — and then `SelfUpdateInstaller.swap` would promote the
        // self-referential symlink into place, destroying the install. A real release built by
        // `scripts/release.sh`/`make bundle` never contains a symlink anywhere (confirmed:
        // `find FreeTalker.app -type l` is always empty for this app), so this can't reject a
        // legitimate update.
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

        // 4. Version binding: the staged bundle's OWN stamped version (`Makefile`'s
        // `plutil -replace CFBundleShortVersionString`) must match what the manifest claims AND
        // be strictly newer than what's currently running — `evaluate(current:manifest:)` above
        // only ever looked at the manifest's *claim*, so without this a manifest claiming an
        // inflated version (say v999.0.0) whose `assetURL` still points at an old signed ZIP
        // would install that old artifact anyway, and replaying the currently-installed ZIP
        // under a fabricated version number would create a permanent "update available" loop.
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

        // 5. Code signature: seal integrity + pinned fingerprint against the running app (see
        // `CodeSignatureVerifier`'s doc comment for why this is a `-R`-pinned check rather than
        // `codesign --verify`'s default trust-chain validation).
        let signatureValid = CodeSignatureVerifier.verifySignature(
            bundlePath: stagedBundle.path, pinnedLeafFingerprintSHA1: runningFingerprintSHA1
        )
        let downloadedFingerprint = CodeSignatureVerifier.leafCertificateFingerprint(
            bundlePath: stagedBundle.path, workingDirectory: stagingRoot
        )
        guard CodeSignatureVerifier.isTrusted(
            signatureValid: signatureValid,
            downloadedFingerprint: downloadedFingerprint,
            runningFingerprint: runningFingerprint
        ) else {
            return .failed("The downloaded update's signature didn't match this app's signing identity — refusing to install it.")
        }

        // 6. Smoke test: the staged binary actually starts (catches a corrupt build or an
        // architecture/framework mismatch before it ever touches the installed app).
        guard verifyLaunches(bundlePath: stagedBundle.path) else {
            return .failed("The downloaded update failed to start — refusing to install it.")
        }

        // 7. Atomic swap with rollback.
        let backupPath = stagingRoot.appendingPathComponent("backup.app")
        let result = SelfUpdateInstaller.swap(
            installedPath: installedBundlePath,
            stagedPath: stagedBundle,
            backupPath: backupPath,
            ops: SelfUpdateInstaller.FileOps(
                moveItem: { try fileManager.moveItem(at: $0, to: $1) },
                removeItem: { try fileManager.removeItem(at: $0) },
                fileExists: { fileManager.fileExists(atPath: $0.path) }
            )
        )
        swapResult = result
        switch result {
        case .success:
            return .success
        case .rolledBack:
            return .failed("The update couldn't be installed — your previous version is unchanged.")
        case .rollbackFailed:
            return .failed(
                "The update failed partway and your previous app couldn't be restored automatically. "
                    + "It's preserved at \(backupPath.path) — move it to \(installedBundlePath.path) manually."
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
    /// deliberately misbehaving child can ignore it indefinitely, and `readDataToEndOfFile`/
    /// `waitUntilExit` below block until the child actually exits and closes its output no
    /// matter what). `SIGKILL` cannot be caught or ignored, so escalating to it after
    /// `killGracePeriod` guarantees this function returns within
    /// `timeout + killGracePeriod`, not "whenever the child feels like exiting." Not `private`
    /// so `SelfUpdaterTests` can exercise the escalation directly against a real child process
    /// that ignores `SIGTERM`.
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
        let killWorkItem = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: terminateWorkItem)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + killGracePeriod, execute: killWorkItem)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        terminateWorkItem.cancel()
        killWorkItem.cancel()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: Relaunch

    /// The swap above replaces the bundle's contents in place at the same path — relaunching
    /// `Bundle.main.bundlePath` opens whatever is now there, i.e. the newly-installed version.
    @MainActor
    static func relaunchAfterUpdate(bundlePath: String = Bundle.main.bundlePath) {
        AppRelaunch.relaunch(bundlePath: bundlePath)
    }
}
