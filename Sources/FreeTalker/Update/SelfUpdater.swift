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
        defer { try? fileManager.removeItem(at: stagingRoot) }

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
        guard
            let contents = try? fileManager.contentsOfDirectory(at: extractedRoot, includingPropertiesForKeys: nil),
            let stagedBundle = contents.first(where: { $0.pathExtension == "app" })
        else {
            return .failed("The downloaded update didn't contain an app bundle.")
        }

        // 4. Code signature: internal validity + pinned fingerprint against the running app.
        let signatureValid = CodeSignatureVerifier.verifySignature(bundlePath: stagedBundle.path)
        let downloadedFingerprint = CodeSignatureVerifier.leafCertificateFingerprint(
            bundlePath: stagedBundle.path, workingDirectory: stagingRoot
        )
        let runningFingerprint = CodeSignatureVerifier.leafCertificateFingerprint(
            bundlePath: installedBundlePath.path, workingDirectory: stagingRoot
        )
        guard CodeSignatureVerifier.isTrusted(
            signatureValid: signatureValid,
            downloadedFingerprint: downloadedFingerprint,
            runningFingerprint: runningFingerprint
        ) else {
            return .failed("The downloaded update's signature didn't match this app's signing identity — refusing to install it.")
        }

        // 5. Smoke test: the staged binary actually starts (catches a corrupt build or an
        // architecture/framework mismatch before it ever touches the installed app).
        guard verifyLaunches(bundlePath: stagedBundle.path) else {
            return .failed("The downloaded update failed to start — refusing to install it.")
        }

        // 6. Atomic swap with rollback.
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
        switch result {
        case .success:
            return .success
        case .rolledBack:
            return .failed("The update couldn't be installed — your previous version is unchanged.")
        case .rollbackFailed:
            return .failed(
                "The update failed partway and the previous app couldn't be restored automatically — "
                    + "check \(installedBundlePath.path)."
            )
        }
    }

    /// Launches the staged binary with `--verify-launch`, which exits immediately (see
    /// `FreeTalkerApp.init`) before touching TCC, the single-instance lease, or any user state.
    /// A crash (missing/incompatible framework, corrupt binary) reports a non-zero/aborted
    /// status just as reliably as an explicit failure would.
    private static func verifyLaunches(bundlePath: String, timeout: TimeInterval = 10) -> Bool {
        let executable = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/MacOS/FreeTalker")
        return runProcess(executable.path, ["--verify-launch"], timeout: timeout).status == 0
    }

    private static func runProcess(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = 30
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
        let timeoutWorkItem = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWorkItem.cancel()
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
