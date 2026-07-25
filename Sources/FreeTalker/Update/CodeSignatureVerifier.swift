import Foundation

/// Verifies a downloaded `FreeTalker.app` before `SelfUpdater` swaps it in. Two checks, both
/// required, and both trust-store-independent:
///
/// 1. `verifySignature` — the bundle's own signature is internally valid (nothing modified
///    since it was signed) AND its leaf certificate matches a caller-supplied fingerprint pin,
///    checked via an explicit `-R` code requirement rather than `codesign`'s default validation.
/// 2. `leafCertificateFingerprint` + `isTrusted` — an independent, `openssl`-only comparison of
///    the downloaded and running bundles' leaf certificate SHA-256 fingerprints, with no
///    `codesign`/trust-store involvement at all.
///
/// The pin is the actual security boundary. `FreeTalker Dev` is a self-signed certificate
/// (`scripts/make-signing-cert.sh`) that's in nobody's trust store but the machine that created
/// it, so `codesign --verify` with no explicit requirement evaluates the certificate chain
/// against the recipient's OS trust anchors as an unconditional part of "is this a valid
/// signature" — which fails closed with `CSSMERR_TP_NOT_TRUSTED` on every machine except the one
/// where a human manually marked the cert "Always Trust" in Keychain Access (empirically
/// confirmed on this machine: `security dump-trust-settings` shows exactly one explicit
/// per-user trust override, for "FreeTalker Dev" — remove that override and `codesign -s` can't
/// even locate the identity to sign with, let alone would `--verify` accept it). That's a
/// *different* boundary than the one we actually want here: pinning to "whatever signed the app
/// I'm already running" is a trust-on-first-use anchor that never depends on anything fetched
/// over the network (in particular, never on `UpdateManifest`) or on any recipient's local trust
/// store, so it can't be spoofed by compromising the release host, and it can't be defeated by
/// simply not having completed a manual Keychain Access step.
enum CodeSignatureVerifier {
    struct ProcessResult: Equatable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// True only when the bundle's seal is intact (`codesign --verify --deep --strict`) AND it
    /// was signed by the certificate whose SHA-1 fingerprint is `pinnedLeafFingerprintSHA1` —
    /// checked via an explicit `-R="certificate leaf = H\"...\""` requirement instead of
    /// `codesign`'s default certificate-chain-to-trusted-anchor validation.
    ///
    /// Why this avoids `CSSMERR_TP_NOT_TRUSTED`: a requirement naming only
    /// `certificate leaf = H"<hash>"` (no `anchor` clause) is evaluated as a pure hash match —
    /// it never calls into trust-chain evaluation. This isn't a workaround; it's how `codesign`
    /// itself represents a self-signed identity's own Designated Requirement — empirically
    /// confirmed: `codesign -d -r-` on a bundle signed with "FreeTalker Dev" prints exactly
    /// `certificate leaf = H"<hash>"`, no `anchor` clause at all. `--deep --strict` is
    /// unchanged, so tamper detection (seal/hash integrity) is fully enforced either way —
    /// empirically confirmed too: modifying a signed bundle's `Info.plist` after signing still
    /// fails this check (`invalid Info.plist (plist or signature have been modified)`, exit 1),
    /// and pinning to the wrong certificate on an otherwise-untampered bundle also fails it
    /// (`code failed to satisfy specified code requirement(s)`, exit 3) — two distinct,
    /// specific failures, neither of which is `CSSMERR_TP_NOT_TRUSTED`.
    ///
    /// The hash must be SHA-1 (40 hex characters) — this `codesign` build rejects a SHA-256
    /// (64 hex character) hash for the `H"..."` certificate operator with "invalid hash
    /// length" (empirically confirmed). That's fine: this is a structural-match pin, not a
    /// collision-resistance requirement, and it's checked in addition to, not instead of, the
    /// SHA-256 `isTrusted` comparison below.
    static func verifySignature(
        bundlePath: String,
        pinnedLeafFingerprintSHA1: String,
        run: (String, [String]) -> ProcessResult = Self.run
    ) -> Bool {
        let requirement = "certificate leaf = H\"\(pinnedLeafFingerprintSHA1)\""
        return run(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", "-R=\(requirement)", bundlePath]
        ).status == 0
    }

    /// Fingerprint of the bundle's leaf signing certificate (`sha256` by default; pass `"sha1"`
    /// to get the format `verifySignature`'s `-R` pin needs), or `nil` if the bundle is
    /// unsigned/ad-hoc-signed (ad-hoc has no certificate to extract) or extraction failed. A
    /// `nil` result on either side of a comparison must always fail closed — see `isTrusted`.
    ///
    /// Every call gets its own fresh, uniquely-named extraction subdirectory under
    /// `workingDirectory`, created here and removed again before returning. This is the fix for
    /// a real bug: `codesign --extract-certificates=<prefix>` exits 0 even for ad-hoc-signed
    /// code, where there's no certificate to extract and nothing is written — if two calls ever
    /// shared one extraction prefix (as they used to, both hardcoded to
    /// `<workingDirectory>/codesign-cert`), a *successful* extraction for one bundle (e.g. an
    /// attacker's downloaded ZIP) would leave its certificate file sitting at that path, and a
    /// *no-op* extraction for a different, ad-hoc-signed bundle (e.g. the currently running app)
    /// would then silently read that leftover file back as its own result — an ad-hoc running
    /// app's fingerprint would resolve to the attacker's certificate instead of `nil`, and
    /// `isTrusted` would compare the attacker's certificate against itself and accept it. With a
    /// fresh UUID subdirectory per call, "no file at `leafCertPath`" can only ever mean *this*
    /// extraction produced nothing — never a leftover from an unrelated one.
    static func leafCertificateFingerprint(
        bundlePath: String,
        workingDirectory: URL,
        digest: String = "sha256",
        run: (String, [String]) -> ProcessResult = Self.run,
        fileManager: FileManager = .default
    ) -> String? {
        let extractionDirectory = workingDirectory.appendingPathComponent(
            "codesign-cert-\(UUID().uuidString)", isDirectory: true
        )
        guard (try? fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)) != nil
        else { return nil }
        defer { try? fileManager.removeItem(at: extractionDirectory) }

        // codesign requires the prefix as `--extract-certificates=<prefix>` (one argument, `=`
        // joined) — passed as two separate argv elements it silently extracts nothing.
        let extractPrefix = extractionDirectory.appendingPathComponent("leaf").path
        let extraction = run("/usr/bin/codesign", ["-d", "--extract-certificates=\(extractPrefix)", bundlePath])
        let leafCertPath = extractPrefix + "0"
        // An ad-hoc/unsigned bundle makes `codesign --extract-certificates` exit 0 while
        // writing nothing — checking both the exit status AND the file's actual presence (in
        // this call's own fresh directory, per the fix above) is what makes "no certificate"
        // an explicit, unambiguous failure rather than something inferred from a process exit
        // code that doesn't by itself distinguish "no cert" from "cert extracted".
        guard extraction.status == 0, fileManager.fileExists(atPath: leafCertPath) else { return nil }
        let fingerprintResult = run(
            "/usr/bin/openssl",
            ["x509", "-inform", "DER", "-in", leafCertPath, "-noout", "-fingerprint", "-\(digest)"]
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

    /// `codesign`'s `H"..."` requirement operator wants a bare hex string — no colons. Strips
    /// them from `openssl`'s `AA:BB:CC...` formatting and lowercases (the comparison is
    /// case-insensitive at the `openssl`/hex level, but `codesign`'s parser is picky about
    /// mixed case in practice, so normalize before it ever gets there).
    static func stripFingerprintColons(_ fingerprint: String) -> String {
        fingerprint.replacingOccurrences(of: ":", with: "").lowercased()
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
