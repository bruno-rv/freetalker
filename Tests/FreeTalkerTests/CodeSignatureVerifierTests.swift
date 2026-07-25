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

        #expect(CodeSignatureVerifier.verifySignature(bundlePath: artifact.path))

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
