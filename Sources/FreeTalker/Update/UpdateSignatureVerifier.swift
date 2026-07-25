import CryptoKit
import Foundation

/// Verifies a downloaded update's detached Ed25519 signature — the actual trust boundary for
/// self-update. Replaces the previous certificate-fingerprint pin (`CodeSignatureVerifier`,
/// removed): that mechanism required `codesign --verify` to accept the self-signed
/// "FreeTalker Dev" certificate's trust chain, which fails closed with `CSSMERR_TP_NOT_TRUSTED`
/// on every machine except the one where a human manually marked the cert "Always Trust" in
/// Keychain Access — meaning it could never actually verify anything except on the release
/// author's own machine. An Ed25519 signature has no trust-chain/keychain dependency at all: the
/// trust anchor is simply "does this signature verify against the public key compiled into the
/// binary I'm already running," the same approach Sparkle uses.
enum UpdateSignatureVerifier {
    enum Result: Equatable {
        case valid
        case missingSignature
        case invalidEncoding
        case mismatch
    }

    /// `data` must be the raw downloaded bytes, verified BEFORE anything is unzipped or
    /// executed — see the call site in `SelfUpdater.runUpdate`. `signatureBase64` is
    /// `UpdateManifest.signature`, expected to decode to a 64-byte raw Ed25519 signature (what
    /// `openssl pkeyutl -sign -rawin` / `Curve25519.Signing.PrivateKey.signature(for:)` both
    /// produce) — `publicKey.isValidSignature` itself validates the length, so a wrong-size blob
    /// simply reports `.mismatch` rather than crashing.
    static func verify(
        data: Data, signatureBase64: String?, publicKey: Curve25519.Signing.PublicKey
    ) -> Result {
        guard let signatureBase64, !signatureBase64.isEmpty else { return .missingSignature }
        guard let signature = Data(base64Encoded: signatureBase64) else { return .invalidEncoding }
        return publicKey.isValidSignature(signature, for: data) ? .valid : .mismatch
    }
}
