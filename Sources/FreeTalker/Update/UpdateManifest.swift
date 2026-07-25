import Foundation

/// Published at a stable URL (`https://github.com/<owner>/<repo>/releases/latest/download/latest.json`
/// — GitHub always resolves that path to the newest published release's matching asset, see
/// `scripts/release.sh`) alongside every release's signed zip.
///
/// `sha256` only proves the download wasn't corrupted or tampered with in transit — it is
/// NOT the authenticity boundary, since this manifest itself comes from the same host as the
/// release and would be attacker-suppliable if that host were compromised. The actual
/// authenticity check is `CodeSignatureVerifier`'s certificate-fingerprint pin against the
/// *running* app's own signing certificate, which never depends on anything in this file.
struct UpdateManifest: Codable, Equatable, Sendable {
    let version: String
    let assetURL: URL
    let sha256: String
}
