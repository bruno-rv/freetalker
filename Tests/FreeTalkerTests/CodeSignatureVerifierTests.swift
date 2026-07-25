import Foundation
import Testing
@testable import FreeTalker

@Suite struct CodeSignatureVerifierTests {
    /// True only when the local "FreeTalker Dev" signing identity (`scripts/make-signing-cert.sh`)
    /// is present in the login keychain. Real signing needs it; without it, this suite's
    /// integration test degrades to a no-op rather than a false failure on a machine that
    /// hasn't run the one-time cert setup — the identity is deliberately machine-local (README:
    /// "the private key stays on the author's machine").
    static var signingIdentityAvailable: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-identity", "-p", "codesigning"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return false }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return output.contains("FreeTalker Dev")
    }

    /// Signs a real throwaway file with the actual local identity and round-trips it through
    /// `CodeSignatureVerifier` — the same `codesign`/`openssl` calls `SelfUpdater` makes against
    /// a real downloaded bundle, not a hand-invented fingerprint string.
    @Test(.enabled(if: Self.signingIdentityAvailable))
    func signedArtifactVerifiesAndItsFingerprintMatchesItself() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let artifact = tempDir.appendingPathComponent("artifact")
        try Data("FreeTalker code signature test".utf8).write(to: artifact)

        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-s", "FreeTalker Dev", artifact.path]
        try sign.run()
        sign.waitUntilExit()
        #expect(sign.terminationStatus == 0)

        let sha1 = CodeSignatureVerifier.leafCertificateFingerprint(
            bundlePath: artifact.path, workingDirectory: tempDir, digest: "sha1"
        )
        #expect(sha1 != nil)
        #expect(CodeSignatureVerifier.verifySignature(
            bundlePath: artifact.path, pinnedLeafFingerprintSHA1: CodeSignatureVerifier.stripFingerprintColons(sha1 ?? "")
        ))

        let fingerprint = CodeSignatureVerifier.leafCertificateFingerprint(
            bundlePath: artifact.path, workingDirectory: tempDir
        )
        #expect(fingerprint != nil)
        #expect(!(fingerprint ?? "").isEmpty)

        // The same artifact compared against itself is exactly the "downloaded == running"
        // trusted case.
        #expect(CodeSignatureVerifier.isTrusted(
            signatureValid: true, downloadedFingerprint: fingerprint, runningFingerprint: fingerprint
        ))
    }

    /// Finding 2's empirical proof, pinned as a regression test: seal-integrity tampering is
    /// still caught by the `-R`-pinned `verifySignature`, even though it no longer relies on
    /// `codesign`'s default trust-chain evaluation. Signs a real throwaway file, tampers with it
    /// AFTER signing (appends a byte), and confirms the pinned check still fails — a verifier
    /// that dropped `--deep --strict` (or the whole seal check) while keeping only the
    /// requirement pin would incorrectly pass this.
    @Test(.enabled(if: Self.signingIdentityAvailable))
    func verifySignatureStillRejectsATamperedArtifactEvenWithACorrectPin() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let artifact = tempDir.appendingPathComponent("artifact")
        try Data("FreeTalker code signature tamper test".utf8).write(to: artifact)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-s", "FreeTalker Dev", artifact.path]
        try sign.run()
        sign.waitUntilExit()
        #expect(sign.terminationStatus == 0)

        let sha1 = try #require(CodeSignatureVerifier.leafCertificateFingerprint(
            bundlePath: artifact.path, workingDirectory: tempDir, digest: "sha1"
        ))
        let pin = CodeSignatureVerifier.stripFingerprintColons(sha1)
        #expect(CodeSignatureVerifier.verifySignature(bundlePath: artifact.path, pinnedLeafFingerprintSHA1: pin))

        let handle = try FileHandle(forWritingTo: artifact)
        handle.seekToEndOfFile()
        handle.write(Data("x".utf8))
        try handle.close()

        #expect(!CodeSignatureVerifier.verifySignature(bundlePath: artifact.path, pinnedLeafFingerprintSHA1: pin))
    }

    /// Finding 2's other half: a validly-signed, untampered artifact still fails the check when
    /// pinned to the WRONG certificate — the pin is an identity check, not just an integrity
    /// check.
    @Test(.enabled(if: Self.signingIdentityAvailable))
    func verifySignatureRejectsAValidArtifactPinnedToTheWrongCertificate() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let artifact = tempDir.appendingPathComponent("artifact")
        try Data("FreeTalker code signature wrong-pin test".utf8).write(to: artifact)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-s", "FreeTalker Dev", artifact.path]
        try sign.run()
        sign.waitUntilExit()
        #expect(sign.terminationStatus == 0)

        let wrongPin = String(repeating: "0", count: 40)
        #expect(!CodeSignatureVerifier.verifySignature(bundlePath: artifact.path, pinnedLeafFingerprintSHA1: wrongPin))
    }

    @Test(.enabled(if: Self.signingIdentityAvailable))
    func unsignedArtifactHasNoExtractableFingerprint() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let artifact = tempDir.appendingPathComponent("artifact")
        try Data("never signed".utf8).write(to: artifact)

        let fingerprint = CodeSignatureVerifier.leafCertificateFingerprint(
            bundlePath: artifact.path, workingDirectory: tempDir
        )
        #expect(fingerprint == nil)
    }

    /// Finding 1's exact reproduction: extract a REAL signed artifact's certificate into a
    /// shared working directory first (as `SelfUpdater` does for the downloaded bundle), then
    /// extract an ad-hoc-signed (no certificate at all) artifact into that SAME working
    /// directory (as it does for the running app). Before the fix, both calls wrote to the same
    /// hardcoded `codesign-cert` prefix, so the second (ad-hoc, no-op) extraction would silently
    /// read back the first call's leftover certificate file instead of correctly reporting
    /// `nil`. This is the actual bug, reproduced with two real `codesign` invocations sharing
    /// one directory — not a mocked/hand-invented collision.
    @Test(.enabled(if: Self.signingIdentityAvailable))
    func adHocExtractionAfterASignedExtractionInTheSameDirectoryDoesNotLeakThePriorCertificate() throws {
        let sharedWorkingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sharedWorkingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sharedWorkingDirectory) }

        let signedArtifact = sharedWorkingDirectory.appendingPathComponent("signed-artifact")
        try Data("signed".utf8).write(to: signedArtifact)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-s", "FreeTalker Dev", signedArtifact.path]
        try sign.run()
        sign.waitUntilExit()
        #expect(sign.terminationStatus == 0)

        // Extract the SIGNED artifact's certificate first, into the shared directory — this is
        // the call that, pre-fix, left a leftover certificate file at a shared, predictable path.
        let signedFingerprint = CodeSignatureVerifier.leafCertificateFingerprint(
            bundlePath: signedArtifact.path, workingDirectory: sharedWorkingDirectory
        )
        #expect(signedFingerprint != nil)

        // Now extract from an AD-HOC signed artifact using the SAME shared working directory —
        // this must report nil (no certificate), never the previous call's leftover.
        let adHocArtifact = sharedWorkingDirectory.appendingPathComponent("adhoc-artifact")
        try Data("ad hoc".utf8).write(to: adHocArtifact)
        let adHocSign = Process()
        adHocSign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        adHocSign.arguments = ["-s", "-", adHocArtifact.path]
        try adHocSign.run()
        adHocSign.waitUntilExit()
        #expect(adHocSign.terminationStatus == 0)

        let adHocFingerprint = CodeSignatureVerifier.leafCertificateFingerprint(
            bundlePath: adHocArtifact.path, workingDirectory: sharedWorkingDirectory
        )
        #expect(adHocFingerprint == nil)
    }

    // MARK: Pure decision logic (unit-tested without touching codesign/openssl at all)

    @Test func isTrustedRejectsMismatchedFingerprints() {
        #expect(!CodeSignatureVerifier.isTrusted(
            signatureValid: true, downloadedFingerprint: "AA:BB", runningFingerprint: "CC:DD"
        ))
    }

    @Test func isTrustedFailsClosedWhenEitherFingerprintIsMissing() {
        #expect(!CodeSignatureVerifier.isTrusted(
            signatureValid: true, downloadedFingerprint: nil, runningFingerprint: "AA:BB"
        ))
        #expect(!CodeSignatureVerifier.isTrusted(
            signatureValid: true, downloadedFingerprint: "AA:BB", runningFingerprint: nil
        ))
        #expect(!CodeSignatureVerifier.isTrusted(
            signatureValid: true, downloadedFingerprint: "", runningFingerprint: "AA:BB"
        ))
    }

    @Test func isTrustedFailsClosedWhenSignatureItselfIsInvalidEvenIfFingerprintsMatch() {
        #expect(!CodeSignatureVerifier.isTrusted(
            signatureValid: false, downloadedFingerprint: "AA:BB", runningFingerprint: "AA:BB"
        ))
    }

    @Test func isTrustedAcceptsCaseInsensitiveMatch() {
        #expect(CodeSignatureVerifier.isTrusted(
            signatureValid: true, downloadedFingerprint: "aa:bb:cc", runningFingerprint: "AA:BB:CC"
        ))
    }

    @Test func parseFingerprintExtractsHexDigestFromOpensslOutput() {
        #expect(CodeSignatureVerifier.parseFingerprint("sha256 Fingerprint=13:B5:20:75\n") == "13:B5:20:75")
        #expect(CodeSignatureVerifier.parseFingerprint("SHA256 Fingerprint=AA\n") == "AA")
        #expect(CodeSignatureVerifier.parseFingerprint("no equals sign here") == nil)
        #expect(CodeSignatureVerifier.parseFingerprint("Fingerprint=\n") == nil)
    }
}
