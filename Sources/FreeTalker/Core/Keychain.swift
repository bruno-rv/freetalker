import Foundation
import Security

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
        /// Legacy shared Cloud STT account retained for one-time migration. New writes use the
        /// provider-scoped account below so switching providers cannot overwrite a secret.
        static let cloudSTTKey = "cloudSTTAPIKey"
        static func cloudSTTKey(for provider: CloudSTTProviderKind) -> String {
            "cloudSTTAPIKey-\(provider.rawValue)"
        }
        /// Legacy shared BYOK LLM key account, from before per-provider scoping. Migrated once
        /// at real app startup into the active provider's scoped
        /// account — see `CloudLLMKeyMigration`. Kept as a named constant so the migration (and
        /// any future audit) can still find it.
        static let legacyCloudLLMKey = "cloudLLMAPIKey"
        static func cloudLLMKey(for provider: LLMProviderKind) -> String {
            "cloudLLMAPIKey-\(provider.rawValue)"
        }
        /// Codex round-3 Finding 1: the automation folder's security-scoped bookmark, moved here
        /// from `UserDefaults` — see `AutomationFolderBookmarkStore` below.
        static let automationFolderBookmark = "automationFolderBookmark"
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

enum CloudSTTCredentialWriter {
    @discardableResult
    static func update(
        _ value: String,
        account: String,
        store: SecretStore = KeychainSecretStore()
    ) -> Bool {
        let succeeded = value.isEmpty
            ? store.delete(account: account)
            : store.set(value, account: account)
        return succeeded
    }
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

/// Codex round-3 Finding 1 (HIGH, unauthenticated bookmark provenance): a `UserDefaults` path or
/// bookmark is writable by any same-user process — `defaults write org.freetalker.app
/// automationFolderBookmark <forged bookmark for />` before FreeTalker even launches is the round-2
/// `defaults write` attack re-encoded as bookmark `Data`, and `AutomationFileAuthorization` has no
/// way to tell that forged bookmark from one `SettingsView`'s folder picker legitimately created.
///
/// The Keychain closes this: `SecItemAdd`/`SecItemCopyMatching` scope a generic-password item to
/// the creating app's own code-signing identity by default (a distinct access group per app,
/// unlike the plist `defaults` edits directly with no identity check at all), so a same-user
/// process without FreeTalker's own signing identity can neither forge nor overwrite this item. A
/// missing or unreadable value fails closed the same way an absent bookmark already does in
/// `AutomationFileAuthorization.authorize` — the user must choose the folder again in Settings.
///
/// Reuses the existing String-based `Keychain`/`SecretStore` surface (base64-encoding the
/// bookmark `Data` at the boundary) rather than adding a parallel Data-typed Keychain API —
/// follows `CloudLLMCredentialWriter`/`CloudSTTCredentialWriter`'s exact shape immediately above,
/// including accepting an injectable `SecretStore` so tests never touch the real system Keychain.
enum AutomationFolderBookmarkStore {
    @discardableResult
    static func set(_ bookmark: Data?, store: SecretStore = KeychainSecretStore()) -> Bool {
        guard let bookmark else {
            return store.delete(account: Keychain.Account.automationFolderBookmark)
        }
        return store.set(bookmark.base64EncodedString(), account: Keychain.Account.automationFolderBookmark)
    }

    static func get(store: SecretStore = KeychainSecretStore()) -> Data? {
        guard let encoded = store.get(account: Keychain.Account.automationFolderBookmark) else { return nil }
        return Data(base64Encoded: encoded)
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

enum CloudSTTKeyMigration {
    static func migrateIfNeeded(provider: CloudSTTProviderKind, store: SecretStore) {
        let targetAccount = Keychain.Account.cloudSTTKey(for: provider)
        if let existing = store.get(account: targetAccount),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = store.delete(account: Keychain.Account.cloudSTTKey)
            return
        }
        let legacyAccount = Keychain.Account.cloudSTTKey
        guard let legacyValue = store.get(account: legacyAccount), !legacyValue.isEmpty else { return }
        guard store.set(legacyValue, account: targetAccount) else { return }
        guard store.get(account: targetAccount) == legacyValue else { return }
        _ = store.delete(account: legacyAccount)
    }
}
