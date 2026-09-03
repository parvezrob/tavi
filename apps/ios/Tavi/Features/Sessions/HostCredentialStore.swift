import Foundation
import Security

// Owns the pairing credentials (#31, #50). A credential is shell access to
// the paired computer, so it lives in the Keychain — this device only,
// available when unlocked — never in UserDefaults. One item per paired
// host, keyed by the host's id, so unpairing one computer removes exactly
// its credential and leaves the others alone.
protocol HostCredentialStoring {
    func load(hostId: String) -> String
    func save(_ credential: String, hostId: String)
    func delete(hostId: String)
    func deleteAll()
    func migrateLegacyCredential(toHostId hostId: String) -> Bool
}

// The Keychain itself, as something HostFleet can be handed; a unit test
// hands in its own so the fleet's bookkeeping is testable off-device (#105).
struct KeychainCredentials: HostCredentialStoring {
    func load(hostId: String) -> String { HostCredentialStore.load(hostId: hostId) }
    func save(_ credential: String, hostId: String) { HostCredentialStore.save(credential, hostId: hostId) }
    func delete(hostId: String) { HostCredentialStore.delete(hostId: hostId) }
    func deleteAll() { HostCredentialStore.deleteAll() }
    func migrateLegacyCredential(toHostId hostId: String) -> Bool {
        HostCredentialStore.migrateLegacyCredential(toHostId: hostId)
    }
}

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
    // pre-#31 UserDefaults token) under the migrated host's id. Returns
    // false — and touches nothing — when the Keychain cannot be read or
    // written right now, so the caller leaves the legacy state for the
    // next launch. The old copies are removed only after the new item
    // reads back.
    static func migrateLegacyCredential(toHostId hostId: String, defaults: UserDefaults = .standard) -> Bool {
        let (legacyItem, status) = read(account: legacyAccount)
        guard status == errSecSuccess || status == errSecItemNotFound else { return false }
        let legacy = legacyItem ?? defaults.string(forKey: legacyDefaultsKey) ?? ""
        if !legacy.isEmpty, load(hostId: hostId).isEmpty {
            save(legacy, hostId: hostId)
            guard load(hostId: hostId) == legacy else { return false }
        }
        SecItemDelete(baseQuery(account: legacyAccount) as CFDictionary)
        defaults.removeObject(forKey: legacyDefaultsKey)
        return true
    }

    private static func load(account: String) -> String {
        read(account: account).value ?? ""
    }

    // The status matters: "not there" and "not readable right now" (the
    // device has not been unlocked yet) must not look the same to a
    // migration that deletes what it thinks it moved.
    private static func read(account: String) -> (value: String?, status: OSStatus) {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return (nil, status)
        }
        return (token, status)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
