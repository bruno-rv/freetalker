import Foundation
import Security

/// Thin wrapper over the Security framework's Keychain Services C API for storing BYOK
/// API keys. Never store secrets in UserDefaults — see PLAN.md step 3/4 (BYOK, Keychain).
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
        static let cloudLLMKey = "cloudLLMAPIKey"
    }
}
