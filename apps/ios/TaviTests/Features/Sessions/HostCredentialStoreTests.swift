import Foundation
@testable import Tavi
import Testing

// Probed once for the whole suite: the probe is itself a write, and a test
// host without a usable Keychain skips these rather than failing them.
private enum Keychain {
    static let answers: Bool = {
        let probe = "tavi.tests.probe"
        HostCredentialStore.save("probe", hostId: probe)
        let readable = HostCredentialStore.load(hostId: probe) == "probe"
        HostCredentialStore.delete(hostId: probe)
        return readable
    }()
}

// A pairing credential is shell access to the computer, so it lives in the
// Keychain, one item per paired host (#31, #50). These are round trips
// against the real Keychain; the suite is serialized because the store is
// one shared thing.
@Suite(.serialized, .enabled(if: Keychain.answers))
struct HostCredentialStoreTests {
    @Test func savesAndReadsBackOneComputersCredential() {
        HostCredentialStore.save("token-a", hostId: "tavi.tests.a")
        defer { HostCredentialStore.delete(hostId: "tavi.tests.a") }
        #expect(HostCredentialStore.load(hostId: "tavi.tests.a") == "token-a")
    }

    @Test func aSecondSaveReplacesTheCredentialRatherThanAddingOne() {
        HostCredentialStore.save("token-a", hostId: "tavi.tests.a")
        HostCredentialStore.save("token-b", hostId: "tavi.tests.a")
        defer { HostCredentialStore.delete(hostId: "tavi.tests.a") }
        #expect(HostCredentialStore.load(hostId: "tavi.tests.a") == "token-b")
    }

    // Unpairing one computer removes exactly its credential (#50).
    @Test func deletingOneComputerLeavesTheOthersAlone() {
        HostCredentialStore.save("token-a", hostId: "tavi.tests.a")
        HostCredentialStore.save("token-b", hostId: "tavi.tests.b")
        defer { HostCredentialStore.delete(hostId: "tavi.tests.b") }
        HostCredentialStore.delete(hostId: "tavi.tests.a")
        #expect(HostCredentialStore.load(hostId: "tavi.tests.b") == "token-b")
    }

    @Test func anEmptyCredentialRemovesTheItemRatherThanStoringNothing() {
        HostCredentialStore.save("token-a", hostId: "tavi.tests.a")
        HostCredentialStore.save("", hostId: "tavi.tests.a")
        #expect(HostCredentialStore.load(hostId: "tavi.tests.a").isEmpty)
    }

    @Test func aFullResetLeavesNoCredentialBehind() {
        HostCredentialStore.save("token-a", hostId: "tavi.tests.a")
        HostCredentialStore.save("token-b", hostId: "tavi.tests.b")
        HostCredentialStore.deleteAll()
        #expect(HostCredentialStore.load(hostId: "tavi.tests.b").isEmpty)
    }

    // The pre-#31 token sat in UserDefaults; the migration moves it under
    // the migrated host's id so nobody has to pair again.
    @Test func theTokenFromBeforeTheKeychainMovesUnderItsHostsId() throws {
        let defaults = try #require(UserDefaults(suiteName: "tavi.tests.migration"))
        defer {
            HostCredentialStore.delete(hostId: "tavi.tests.a")
            defaults.removePersistentDomain(forName: "tavi.tests.migration")
        }
        HostCredentialStore.delete(hostId: "default")
        HostCredentialStore.delete(hostId: "tavi.tests.a")
        defaults.set("legacy-token", forKey: "tavi.dev.token")

        #expect(HostCredentialStore.migrateLegacyCredential(toHostId: "tavi.tests.a", defaults: defaults))
        #expect(HostCredentialStore.load(hostId: "tavi.tests.a") == "legacy-token")
    }

    @Test func aMigrationThatLandedLeavesNoLegacyCopyBehind() throws {
        let defaults = try #require(UserDefaults(suiteName: "tavi.tests.migration"))
        defer {
            HostCredentialStore.delete(hostId: "tavi.tests.a")
            defaults.removePersistentDomain(forName: "tavi.tests.migration")
        }
        HostCredentialStore.delete(hostId: "default")
        HostCredentialStore.delete(hostId: "tavi.tests.a")
        defaults.set("legacy-token", forKey: "tavi.dev.token")

        _ = HostCredentialStore.migrateLegacyCredential(toHostId: "tavi.tests.a", defaults: defaults)
        #expect(defaults.string(forKey: "tavi.dev.token") == nil)
    }
}
