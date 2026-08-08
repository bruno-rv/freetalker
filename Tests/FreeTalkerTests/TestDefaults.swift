import Foundation

/// A per-test `UserDefaults` suite whose name is **stable across runs**.
///
/// The pattern this replaces — `UserDefaults(suiteName: "<Suite>.\(UUID())")` — invents a new
/// preference domain on every run, and a `UserDefaults` suite is a file in `~/Library/Preferences`.
/// Removing the domain afterwards does not reclaim the file: `removePersistentDomain` empties it,
/// but cfprefsd writes a 42-byte `{}` stub back after the test process exits. Measured with a
/// 120-second settling window, counts went 13 → 14 → 17 → 18 across three runs, and unlinking the
/// file in-process loses the same race — the daemon writes after the process is gone. Nothing
/// in-process can stop the file appearing.
///
/// So this stops inventing names instead. `#function` resolves at the *call site*, so each test
/// gets its own domain; the counter distinguishes repeated calls within one test. The set of names
/// is therefore the same on every run, the same files are reused, and the count stops growing.
/// It was 69,632 files and 300 MB when this was written, accumulating since 11 July.
///
/// `removePersistentDomain` at construction is what makes reuse safe: emptying a domain works
/// reliably, so a reused file starts every test empty. Only file *creation* is unavoidable.
enum TestDefaults {
    /// A `let`-held box rather than a `static var` dictionary: swift-testing runs suites in
    /// parallel, and strict concurrency rejects nonisolated mutable global state outright.
    private final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Int] = [:]

        func next(_ key: String) -> Int {
            lock.withLock {
                values[key, default: 0] += 1
                return values[key]!
            }
        }
    }

    private static let counters = Counters()

    /// - Parameters:
    ///   - test: the calling test's name. Left to `#function` on purpose — passing it explicitly
    ///     defeats the point, since two tests sharing a name share a domain.
    ///   - file: the calling file, so two suites with same-named tests do not collide.
    static func isolated(_ test: String = #function, file: String = #fileID) -> UserDefaults {
        let name = freshSuiteName(test, file: file)
        // Force-unwrap deliberately: `UserDefaults(suiteName:)` returns nil only for reserved
        // names (the app's own bundle id, or the global domain), and this name is neither. A
        // silent fallback to `.standard` here would write the user's real settings, which is the
        // failure this whole helper exists to prevent.
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        // Several suites already carried their domain name in this key so a `remove(_:)` helper
        // could find it later. Keeping it means those helpers keep working untouched — their
        // removal is now redundant rather than load-bearing, since construction empties.
        defaults.set(name, forKey: "testSuiteName")
        return defaults
    }

    /// A stable name whose domain is already **emptied**, for callers that cannot take a
    /// ready-made instance — a `UserDefaults` subclass has to construct itself, and some suites
    /// keep the name for their own teardown.
    ///
    /// It empties rather than only naming, because stable names are reused across runs: without
    /// this, a value written by yesterday's run would still be there at the start of today's. That
    /// is the one hazard reuse introduces, and it is fixed here rather than at 30-odd call sites.
    static func freshSuiteName(_ test: String = #function, file: String = #fileID) -> String {
        let base = file
            .replacingOccurrences(of: "/", with: ".")
            .replacingOccurrences(of: ".swift", with: "")
        let key = "\(base).\(test)"
        let name = "\(key).\(counters.next(key))"
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        return name
    }
}
