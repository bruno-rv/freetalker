import Foundation
import Security

/// Thin wrapper over the Security framework's Keychain Services C API for storing BYOK
/// API keys. Never store secrets in UserDefaults — see PLAN.md step 3/4 (BYOK, Keychain).
enum Keychain {
    private static let service = "org.freetalker.app"

    /// Updates the existing item if one is present, otherwise adds a new one. Returns whether
    /// the write succeeded — deleting the existing item unconditionally before writing (the
    /// previous behavior) meant a transient `SecItemAdd` failure erased a valid secret. See
    /// Round 1 Codex finding 13. Callers may ignore the result, but the OSStatus is never
    /// silently discarded here.
    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum Account {
        static let cloudSTTKey = "cloudSTTAPIKey"
        /// Legacy shared BYOK LLM key account, from before per-provider scoping. Migrated once
        /// (at real app startup, not under `--self-check`) into the active provider's scoped
        /// account — see `CloudLLMKeyMigration`. Kept as a named constant so the migration (and
        /// any future audit) can still find it.
        static let legacyCloudLLMKey = "cloudLLMAPIKey"
        /// Per-provider scoped account: Anthropic/Ollama/OpenAI-compatible keys are stored and
        /// read independently, so switching providers can never send one provider's secret to
        /// another's endpoint. See PLAN.md step 3.
        static func cloudLLMKey(for provider: LLMProviderKind) -> String {
            "cloudLLMAPIKey-\(provider.rawValue)"
        }
    }
}

/// Minimal get/set/delete surface that Keychain-touching logic can be written against, so
/// SelfCheck can exercise migration with an in-memory fake instead of the real Keychain (which
/// would touch real, persistent secret storage from a headless CLT process). See PLAN.md step 3,
/// Round 2 Codex finding 3.
protocol SecretStore {
    func get(account: String) -> String?
    @discardableResult func set(_ value: String, account: String) -> Bool
    func delete(account: String)
}

/// Thin adapter over the real `Keychain` — the only conformer used outside SelfCheck.
struct KeychainSecretStore: SecretStore {
    func get(account: String) -> String? { Keychain.get(account: account) }
    @discardableResult func set(_ value: String, account: String) -> Bool { Keychain.set(value, account: account) }
    func delete(account: String) { Keychain.delete(account: account) }
}

enum CloudLLMKeyMigration {
    /// Copies the legacy shared `cloudLLMKey` item to `provider`'s scoped account, once.
    /// Idempotent: no-ops if the target account already holds a real (trimmed non-empty) value
    /// (a prior migration, or a key the user already set for that provider) — never overwrites
    /// it. A target account that merely *exists* but holds an empty/whitespace-only value (e.g.
    /// left behind by a Settings field that was cleared then never re-saved) does NOT count as
    /// "already migrated" — skipping in that case would strand the legacy key forever, since
    /// `store.get` would keep returning that same blank value on every future launch. Deletes the
    /// legacy item only after verifying (read-back) that the write to the target account actually
    /// succeeded, so a failed write leaves the legacy key intact and no secret is ever silently
    /// dropped. See PLAN.md step 3, Round 2 Codex finding 3.
    static func migrateIfNeeded(provider: LLMProviderKind, store: SecretStore) {
        let targetAccount = Keychain.Account.cloudLLMKey(for: provider)
        if let existing = store.get(account: targetAccount),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        let legacyAccount = Keychain.Account.legacyCloudLLMKey
        guard let legacyValue = store.get(account: legacyAccount), !legacyValue.isEmpty else { return }
        guard store.set(legacyValue, account: targetAccount) else { return }
        guard store.get(account: targetAccount) == legacyValue else { return }
        store.delete(account: legacyAccount)
    }
}
