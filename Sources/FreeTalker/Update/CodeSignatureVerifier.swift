import Foundation

/// Verifies a downloaded `FreeTalker.app` before `SelfUpdateInstaller` swaps it in. Two checks,
/// both required:
///
/// 1. `codesign --verify` — the bundle's own signature is internally valid and nothing has been
///    modified since it was signed.
/// 2. A certificate-fingerprint PIN against the *currently running* app's own leaf signing
///    certificate.
///
/// The pin is the actual security boundary. `FreeTalker Dev` is a self-signed certificate
/// (`scripts/make-signing-cert.sh`) that's in nobody's trust store, so `codesign --verify`
/// alone would happily accept a bundle signed by any other self-signed certificate an attacker
/// controls. Pinning to "whatever signed the app I'm already running" is a trust-on-first-use
/// anchor that never depends on anything fetched over the network (in particular, never on
/// `UpdateManifest`), so it can't be spoofed by compromising the release host.
enum CodeSignatureVerifier {
    struct ProcessResult: Equatable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// True only when `codesign --verify --deep --strict` exits 0 — a corrupt, resigned, or
    /// unsigned bundle fails.
    static func verifySignature(
        bundlePath: String,
        run: (String, [String]) -> ProcessResult = Self.run
    ) -> Bool {
        run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundlePath]).status == 0
    }

    /// SHA-256 fingerprint of the bundle's leaf signing certificate, or `nil` if the bundle is
    /// unsigned/ad-hoc-signed (ad-hoc has no certificate to extract) or extraction failed. A
    /// `nil` result on either side of a comparison must always fail closed — see `isTrusted`.
    static func leafCertificateFingerprint(
        bundlePath: String,
        workingDirectory: URL,
        run: (String, [String]) -> ProcessResult = Self.run,
        fileManager: FileManager = .default
    ) -> String? {
        let extractPrefix = workingDirectory.appendingPathComponent("codesign-cert").path
        // codesign requires the prefix as `--extract-certificates=<prefix>` (one argument, `=`
        // joined) — passed as two separate argv elements it silently extracts nothing.
        let extraction = run("/usr/bin/codesign", ["-d", "--extract-certificates=\(extractPrefix)", bundlePath])
        guard extraction.status == 0 else { return nil }
        let leafCertPath = extractPrefix + "0"
        guard fileManager.fileExists(atPath: leafCertPath) else { return nil }
        let fingerprintResult = run(
            "/usr/bin/openssl",
            ["x509", "-inform", "DER", "-in", leafCertPath, "-noout", "-fingerprint", "-sha256"]
        )
        guard fingerprintResult.status == 0 else { return nil }
        return Self.parseFingerprint(fingerprintResult.stdout)
    }

    /// `openssl x509 ... -fingerprint` prints `SHA256 Fingerprint=AA:BB:...\n` — extract just
    /// the hex digest. Pure and independently testable against real `openssl` output.
    static func parseFingerprint(_ opensslOutput: String) -> String? {
        guard let equalsIndex = opensslOutput.firstIndex(of: "=") else { return nil }
        let digest = opensslOutput[opensslOutput.index(after: equalsIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return digest.isEmpty ? nil : digest
    }

    /// The trust decision itself, pure: both the signature-integrity check and the fingerprint
    /// pin must hold. A `nil`/empty fingerprint on either side (unsigned bundle, ad-hoc-signed
    /// running app with nothing to pin against, or a failed extraction) always fails closed —
    /// there is no "trust anyway" fallback. The comparison is case-insensitive because that's
    /// only `openssl`'s hex-digit casing, not a security relaxation — both sides come from the
    /// same tool.
    static func isTrusted(signatureValid: Bool, downloadedFingerprint: String?, runningFingerprint: String?) -> Bool {
        guard signatureValid,
              let downloadedFingerprint, !downloadedFingerprint.isEmpty,
              let runningFingerprint, !runningFingerprint.isEmpty
        else { return false }
        return downloadedFingerprint.caseInsensitiveCompare(runningFingerprint) == .orderedSame
    }

    private static func run(_ executable: String, _ arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return ProcessResult(status: -1, stdout: "", stderr: "\(error)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
