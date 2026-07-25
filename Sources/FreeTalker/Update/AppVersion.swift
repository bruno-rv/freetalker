import Foundation

/// The running app's version, baked into `Info.plist` at build time (see `Makefile`'s
/// `VERSION`, derived from `git describe --tags`). Falls back to `0.0.0` only when there's no
/// `Info.plist` at all — an executable run directly via `swift build`/`swift run` outside an
/// assembled `.app` bundle — never for a real build.
enum AppVersion {
    static var currentString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var current: SemanticVersion {
        SemanticVersion(string: currentString) ?? SemanticVersion(major: 0, minor: 0, patch: 0)
    }
}
