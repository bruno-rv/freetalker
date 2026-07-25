import CryptoKit
import Foundation
import Testing
@testable import FreeTalker

/// Runs a real `openssl` invocation and returns its stdout bytes, failing the test if the
/// command doesn't exit 0. Used to reproduce the EXACT command sequence
/// `scripts/make-release-signing-key.sh`/`scripts/release.sh` run (Ed25519 keygen, raw
/// signing, `-A` base64) rather than re-deriving equivalent bytes purely in Swift — the point
/// being to exercise the same code path production takes end to end, the same way
/// `SelfUpdaterTests.sha256HexMatchesTheRealShasumTool` cross-checks against real `shasum`.
private func runOpenSSL(_ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["openssl"] + arguments
    let outPipe = Pipe()
    process.standardOutput = outPipe
    try process.run()
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "openssl \(arguments.joined(separator: " ")) failed")
    return data
}

/// Generates a throwaway Ed25519 keypair with real `openssl` calls and returns
/// (private key PEM path, raw 32-byte public key base64 — same DER-tail-32-bytes extraction
/// `scripts/make-release-signing-key.sh` uses for the real compiled-in key).
private func makeThrowawayKeypair(in directory: URL) throws -> (privateKeyPath: URL, publicKeyBase64: String) {
    let privateKeyPath = directory.appendingPathComponent("throwaway-\(UUID().uuidString).pem")
    _ = try runOpenSSL(["genpkey", "-algorithm", "ED25519", "-out", privateKeyPath.path])

    let publicKeyPemPath = directory.appendingPathComponent("throwaway-\(UUID().uuidString)-pub.pem")
    _ = try runOpenSSL(["pkey", "-in", privateKeyPath.path, "-pubout", "-out", publicKeyPemPath.path])
    let publicKeyDER = try runOpenSSL(["pkey", "-pubin", "-in", publicKeyPemPath.path, "-outform", "DER"])
    #expect(publicKeyDER.count == 44)
    let rawPublicKey = publicKeyDER.suffix(32)
    return (privateKeyPath, rawPublicKey.base64EncodedString())
}

/// Signs `payload` with the private key at `privateKeyPath` using the exact command
/// `scripts/release.sh` runs (`pkeyutl -sign -rawin`, then `base64 -A`), returning the base64
/// signature `UpdateManifest.signature` would contain.
private func signWithOpenSSL(payload: Data, privateKeyPath: URL, in directory: URL) throws -> String {
    let payloadPath = directory.appendingPathComponent("payload-\(UUID().uuidString).bin")
    try payload.write(to: payloadPath)
    let signaturePath = directory.appendingPathComponent("sig-\(UUID().uuidString).bin")
    _ = try runOpenSSL(["pkeyutl", "-sign", "-inkey", privateKeyPath.path, "-rawin", "-in", payloadPath.path, "-out", signaturePath.path])
    let base64Data = try runOpenSSL(["base64", "-A", "-in", signaturePath.path])
    return String(data: base64Data, encoding: .utf8) ?? ""
}

@Suite struct UpdateSignatureVerifierTests {
    private var scratchDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateSignatureVerifierTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: The redesign's core claim, end to end with real openssl

    /// The demonstration this feature depends on: a payload signed by the REAL
    /// `openssl genpkey ED25519` + `pkeyutl -sign -rawin` + `base64 -A` sequence
    /// `scripts/release.sh` runs verifies successfully through `UpdateSignatureVerifier`/
    /// `CryptoKit`, using the SAME DER-tail-32-bytes public key extraction
    /// `scripts/make-release-signing-key.sh` uses. If openssl's raw Ed25519 signature encoding
    /// or the DER-to-raw-key extraction ever stopped matching what CryptoKit expects, this is
    /// the test that would catch it — a pure-CryptoKit round-trip (sign and verify both in
    /// Swift) could never catch a production/openssl mismatch the way the colon-stripping bug
    /// escaped the codesign-based design.
    @Test func aRealOpenSSLSignedPayloadVerifiesThroughCryptoKit() throws {
        let dir = scratchDirectory
        defer { try? FileManager.default.removeItem(at: dir) }

        let (privateKeyPath, publicKeyBase64) = try makeThrowawayKeypair(in: dir)
        let payload = Data("FreeTalker-v1.2.3.app.zip payload — \(UUID())".utf8)
        let signatureBase64 = try signWithOpenSSL(payload: payload, privateKeyPath: privateKeyPath, in: dir)

        let publicKey = try #require(UpdatePublicKey.parse(base64: publicKeyBase64))
        let result = UpdateSignatureVerifier.verify(data: payload, signatureBase64: signatureBase64, publicKey: publicKey)
        #expect(result == .valid)
    }

    /// A tampered payload (one byte appended after signing, exactly the class of corruption/MITM
    /// this whole mechanism exists to catch) must fail verification even though the signature
    /// itself is well-formed and was produced by the correct key.
    @Test func aTamperedPayloadFailsVerificationEvenWithACorrectSignatureAndKey() throws {
        let dir = scratchDirectory
        defer { try? FileManager.default.removeItem(at: dir) }

        let (privateKeyPath, publicKeyBase64) = try makeThrowawayKeypair(in: dir)
        let originalPayload = Data("FreeTalker-v1.2.3.app.zip payload — \(UUID())".utf8)
        let signatureBase64 = try signWithOpenSSL(payload: originalPayload, privateKeyPath: privateKeyPath, in: dir)

        var tamperedPayload = originalPayload
        tamperedPayload.append(0x00)

        let publicKey = try #require(UpdatePublicKey.parse(base64: publicKeyBase64))
        let result = UpdateSignatureVerifier.verify(data: tamperedPayload, signatureBase64: signatureBase64, publicKey: publicKey)
        #expect(result == .mismatch)
    }

    /// A validly-signed, untampered payload must still fail when verified against the WRONG
    /// public key — proves the check is an identity check, not just an integrity check. This is
    /// also the scenario a lost/rotated release-signing key produces: every already-built app
    /// (with the OLD public key compiled in) must fail loudly on anything signed by a NEW key,
    /// never silently accept it.
    @Test func aValidSignatureFailsVerificationAgainstTheWrongPublicKey() throws {
        let dir = scratchDirectory
        defer { try? FileManager.default.removeItem(at: dir) }

        let (privateKeyPathA, _) = try makeThrowawayKeypair(in: dir)
        let (_, publicKeyBaseB) = try makeThrowawayKeypair(in: dir)
        let payload = Data("FreeTalker-v1.2.3.app.zip payload — \(UUID())".utf8)
        let signatureBase64 = try signWithOpenSSL(payload: payload, privateKeyPath: privateKeyPathA, in: dir)

        let wrongPublicKey = try #require(UpdatePublicKey.parse(base64: publicKeyBaseB))
        let result = UpdateSignatureVerifier.verify(data: payload, signatureBase64: signatureBase64, publicKey: wrongPublicKey)
        #expect(result == .mismatch)
    }

    // MARK: Pure decision logic

    @Test func verifyReportsMissingSignatureForNilOrEmptyString() throws {
        let publicKey = try #require(UpdatePublicKey.current, "this build's real compiled-in public key must be valid")
        let payload = Data("payload".utf8)
        #expect(UpdateSignatureVerifier.verify(data: payload, signatureBase64: nil, publicKey: publicKey) == .missingSignature)
        #expect(UpdateSignatureVerifier.verify(data: payload, signatureBase64: "", publicKey: publicKey) == .missingSignature)
    }

    @Test func verifyReportsInvalidEncodingForNonBase64Signature() throws {
        let publicKey = try #require(UpdatePublicKey.current)
        let result = UpdateSignatureVerifier.verify(
            data: Data("payload".utf8), signatureBase64: "not valid base64 !!!", publicKey: publicKey
        )
        #expect(result == .invalidEncoding)
    }

    @Test func verifyReportsMismatchForWellFormedButWrongLengthBase64() throws {
        let publicKey = try #require(UpdatePublicKey.current)
        // Valid base64, but not a real 64-byte Ed25519 signature — CryptoKit's
        // `isValidSignature` must reject this rather than crash.
        let result = UpdateSignatureVerifier.verify(
            data: Data("payload".utf8), signatureBase64: Data("too short".utf8).base64EncodedString(), publicKey: publicKey
        )
        #expect(result == .mismatch)
    }
}

@Suite struct UpdatePublicKeyTests {
    /// Fail-closed contract (see `SelfUpdater.runUpdate`'s step 0): an app built without ever
    /// running `scripts/make-release-signing-key.sh` — or one where the compiled-in constant got
    /// corrupted somehow — must report no usable public key, not crash or silently accept
    /// anything.
    @Test func parseReturnsNilForAnEmptyOrMissingKey() {
        #expect(UpdatePublicKey.parse(base64: "") == nil)
    }

    @Test func parseReturnsNilForNonBase64Input() {
        #expect(UpdatePublicKey.parse(base64: "not base64 !!!") == nil)
    }

    /// A syntactically valid base64 string that doesn't decode to exactly 32 bytes (the raw
    /// Ed25519 public key length) must be rejected — accepting a truncated/padded key would
    /// silently narrow (or entirely break) the security this depends on rather than failing
    /// clearly.
    @Test func parseReturnsNilForTheWrongByteLength() {
        #expect(UpdatePublicKey.parse(base64: Data(repeating: 0, count: 31).base64EncodedString()) == nil)
        #expect(UpdatePublicKey.parse(base64: Data(repeating: 0, count: 33).base64EncodedString()) == nil)
    }

    /// The real compiled-in constant, generated by `scripts/make-release-signing-key.sh`, must
    /// itself parse successfully — this is what `SelfUpdater.runUpdate` depends on to ever
    /// verify anything at all.
    @Test func theRealCompiledInPublicKeyParsesSuccessfully() {
        #expect(UpdatePublicKey.current != nil)
    }
}
