import Foundation
import Security

// Owns the pairing token (#31). The token is shell access to the paired Mac,
// so it lives in the Keychain — this device only, available when unlocked —
// never in UserDefaults. The host address is not a secret and stays in
// AppStorage. Per-device credentials and revoke remain Phase D; this is only
// honest storage for the one shared token.
enum HostCredentialStore {
    private static let service = "com.farfield.tavi.host-token"
    private static let account = "default"
    private static let legacyDefaultsKey = "tavi.dev.token"

    static func load() -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return ""
        }
        return token
    }

    static func save(_ token: String) {
        guard !token.isEmpty else {
            delete()
            return
        }
        let payload: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, payload as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(baseQuery.merging(payload) { _, new in new } as CFDictionary, nil)
        }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    // One-time move of a pre-#31 UserDefaults token into the Keychain. The
    // UserDefaults copy is removed unconditionally: leaving both would fix
    // nothing.
    static func migrateFromDefaults(_ defaults: UserDefaults = .standard) {
        if let legacy = defaults.string(forKey: legacyDefaultsKey), !legacy.isEmpty,
           load().isEmpty {
            save(legacy)
        }
        defaults.removeObject(forKey: legacyDefaultsKey)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
