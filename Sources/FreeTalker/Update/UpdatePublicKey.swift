import CryptoKit
import Foundation

/// The public half of the Ed25519 release-signing keypair (see
/// scripts/make-release-signing-key.sh). Compiled into every build — this is the trust anchor
/// `UpdateSignatureVerifier` checks a downloaded release's signature against. It is independent
/// of any machine-local keychain trust. The matching private key never leaves the release
/// signer's machine; regenerating this file with a new keypair is a breaking change for every
/// already-built app, since it can only ever trust the ONE public key it was compiled with.
enum UpdatePublicKey {
    static let base64 = "0mX1eBHprb/TXBqWGAC9mpRmt9+pu/hCMdX2440U5Uk="

    static var current: Curve25519.Signing.PublicKey? { Self.parse(base64: base64) }

    /// Pulled out of `current` so tests can exercise the exact parsing/validation logic
    /// (length check, `CryptoKit` construction) against both this real compiled-in key and
    /// deliberately invalid inputs, without needing a second compiled-in constant.
    static func parse(base64: String) -> Curve25519.Signing.PublicKey? {
        guard let raw = Data(base64Encoded: base64), raw.count == 32,
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { return nil }
        return key
    }
}
