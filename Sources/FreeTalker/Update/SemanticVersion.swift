import Foundation

/// Parses `"v1.2.3"`, `"1.2.3"`, or a `git describe` string like `"v1.2.3-4-gabc1234"` /
/// `"v1.2.3-4-gabc1234-dirty"` (what a plain `swift build`/`make bundle` dev build gets
/// stamped with — see `Makefile`'s `VERSION`). Only the leading MAJOR.MINOR.PATCH triple
/// participates in comparison; the commits-ahead/hash/dirty suffix (present only on
/// unreleased dev builds, never on a tagged release — see `scripts/release.sh`) doesn't
/// change ordering. That's an intentional simplification, not a gap: `SelfUpdater` only ever
/// compares against a manifest published by a release, which is always a clean tag.
struct SemanticVersion: Equatable, Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(string: String) {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        // Drop a `git describe` suffix (`-N-gHASH[-dirty]`) — everything from the first "-".
        let corePart = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let components = corePart.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
