import Foundation

/// Published at a stable URL (`https://github.com/<owner>/<repo>/releases/latest/download/latest.json`
/// — GitHub always resolves that path to the newest published release's matching asset, see
/// `scripts/release.sh`) alongside every release's signed zip.
///
/// `sha256` only proves the download wasn't corrupted in transit — it is NOT the authenticity
/// boundary, since this manifest itself comes from the same host as the release and would be
/// attacker-suppliable if that host were compromised. The actual authenticity check is
/// `signature`: a detached Ed25519 signature (`scripts/make-release-signing-key.sh`,
/// `scripts/release.sh`) verified by `UpdateSignatureVerifier` against the public key compiled
/// into the running app (`UpdatePublicKey`) — a trust anchor that never depends on anything
/// fetched over the network, including this manifest, or on any machine-local keychain trust.
///
/// `signature` is optional at the decode level (rather than making a missing field a generic
/// JSON decode failure) so `SelfUpdater` can report a specific, legible "no signature published"
/// failure instead of an opaque decode error.
struct UpdateManifest: Codable, Equatable, Sendable {
    let version: String
    let assetURL: URL
    let sha256: String
    let signature: String?
}
