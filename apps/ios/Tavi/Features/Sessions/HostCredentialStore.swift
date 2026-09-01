import Foundation
import Security

// Owns the pairing credentials (#31, #50). A credential is shell access to
// the paired computer, so it lives in the Keychain — this device only,
// available when unlocked — never in UserDefaults. One item per paired
// host, keyed by the host's id, so unpairing one computer removes exactly
// its credential and leaves the others alone.
enum HostCredentialStore {
    private static let service = "com.farfield.tavi.host-token"
    // Pre-#50: the single credential of the one paired host.
    private static let legacyAccount = "default"
    // Pre-#31: the token sat in UserDefaults.
    private static let legacyDefaultsKey = "tavi.dev.token"

    static func load(hostId: String) -> String {
        load(account: hostId)
    }

    static func save(_ credential: String, hostId: String) {
        guard !credential.isEmpty else {
            delete(hostId: hostId)
            return
        }
        let payload: [String: Any] = [
            kSecValueData as String: Data(credential.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let query = baseQuery(account: hostId)
        let status = SecItemUpdate(query as CFDictionary, payload as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(payload) { _, new in new } as CFDictionary, nil)
        }
    }

    static func delete(hostId: String) {
        SecItemDelete(baseQuery(account: hostId) as CFDictionary)
    }

    // Every credential Tavi holds, for a full reset.
    static func deleteAll() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
    }

    // One-time move of the single pre-#50 credential (and, before it, the
    // pre-#31 UserDefaults token) under the migrated host's id. The old
    // copies are removed unconditionally: leaving them would fix nothing.
    static func migrateLegacyCredential(toHostId hostId: String, defaults: UserDefaults = .standard) {
        var legacy = load(account: legacyAccount)
        if legacy.isEmpty, let fromDefaults = defaults.string(forKey: legacyDefaultsKey) {
            legacy = fromDefaults
        }
        if !legacy.isEmpty, load(hostId: hostId).isEmpty {
            save(legacy, hostId: hostId)
        }
        SecItemDelete(baseQuery(account: legacyAccount) as CFDictionary)
        defaults.removeObject(forKey: legacyDefaultsKey)
    }

    private static func load(account: String) -> String {
        var query = baseQuery(account: account)
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

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
