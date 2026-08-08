import Foundation

/// A `UserDefaults` that never touches disk, for tests that need their own settings store.
///
/// The alternative — `UserDefaults(suiteName: "<Suite>.<UUID>")` — creates a real preference
/// domain, which is a file in `~/Library/Preferences`. Removing the domain afterwards is not
/// enough: `removePersistentDomain` empties it, but cfprefsd writes a 42-byte stub back after the
/// test process exits, so the file count still climbs by one per test. Measured with a 120 s
/// settling window: 13 → 14 → 17 → 18 across three runs, and `DictationLanguageTests` carries
/// 2,124 such stubs despite calling `removePersistentDomain`. Nothing in-process can prevent it,
/// including unlinking the file, because the daemon writes after the process is gone.
///
/// Overriding these three primitives is sufficient because every typed accessor
/// (`string`/`bool`/`integer`/`double`/`data`/`array`/`stringArray`/`dictionary`/`url`) and KVC
/// funnel through `object(forKey:)` — measured, not assumed. It also isolates *better* than a
/// suite does: a suite still sees the real global domain through the search list, while this sees
/// nothing but what the test put in it.
///
/// One thing it does not support: `register(defaults:)`. Registration lives in a domain that
/// `object(forKey:)` replaces wholesale here, so a registered fallback comes back nil. Nothing in
/// this project registers defaults; if that changes, this breaks silently.
class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any] = [:]

    init() {
        // `suiteName: nil` is the standard domain, which this class then never consults: every
        // read is answered from `storage`.
        super.init(suiteName: nil)!
    }

    override func object(forKey key: String) -> Any? {
        lock.withLock { storage[key] }
    }

    override func set(_ value: Any?, forKey key: String) {
        lock.withLock { storage[key] = value }
    }

    override func removeObject(forKey key: String) {
        lock.withLock { storage[key] = nil }
    }
}
