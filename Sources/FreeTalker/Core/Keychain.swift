import Foundation
import Security

enum Keychain {
    private static let service = "com.bruno.freetalker"

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

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    enum Account {
        static let cloudSTTKey = "cloudSTTAPIKey"
        /// Legacy shared BYOK LLM key account, from before per-provider scoping. Migrated once
        /// at real app startup into the active provider's scoped
        /// account — see `CloudLLMKeyMigration`. Kept as a named constant so the migration (and
        /// any future audit) can still find it.
        static let legacyCloudLLMKey = "cloudLLMAPIKey"
        static func cloudLLMKey(for provider: LLMProviderKind) -> String {
            "cloudLLMAPIKey-\(provider.rawValue)"
        }
    }
}

protocol SecretStore {
    func get(account: String) -> String?
    @discardableResult func set(_ value: String, account: String) -> Bool
    @discardableResult func delete(account: String) -> Bool
}

struct KeychainSecretStore: SecretStore {
    func get(account: String) -> String? { Keychain.get(account: account) }
    @discardableResult func set(_ value: String, account: String) -> Bool { Keychain.set(value, account: account) }
    @discardableResult func delete(account: String) -> Bool { Keychain.delete(account: account) }
}

enum CloudLLMCredentialWriter {
    @discardableResult
    static func update(
        _ value: String,
        account: String,
        store: SecretStore = KeychainSecretStore(),
        notificationCenter: NotificationCenter = .default
    ) -> Bool {
        let succeeded = value.isEmpty
            ? store.delete(account: account)
            : store.set(value, account: account)
        guard succeeded else { return false }
        notificationCenter.post(name: .cloudLLMCredentialsDidChange, object: nil)
        return true
    }
}

enum CloudLLMKeyMigration {
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
        _ = store.delete(account: legacyAccount)
    }
}
