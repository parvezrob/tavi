import Foundation
@testable import Tavi
import Testing

// The upgrade from the one-host app (#46) to the paired-host list (#50):
// nobody re-pairs their computer because they installed a new build. The
// credential move is handed in, so this suite never touches the Keychain.
@Suite(.serialized)
struct PairedHostRegistryTests {
    private static let suiteName = "tavi.tests.registry"

    private static let legacyRecord = #"""
    {"hostName":"studio-mac","fingerprint":"fp-1","deviceId":"device-1",
     "deviceName":"iPhone","pairedAt":0}
    """#

    // The keys a phone updated from the one-host app arrives with.
    private func seedLegacy(_ defaults: UserDefaults, address: String = "https://studio.tailnet.ts.net", record: Bool = true) {
        defaults.set(address, forKey: PairedHostRegistry.legacyAddressKey)
        if record { defaults.set(Data(Self.legacyRecord.utf8), forKey: PairedHostRegistry.legacyRecordKey) }
    }

    private func defaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        return defaults
    }

    @discardableResult
    private func migrate(_ defaults: UserDefaults, credentialMoves: Bool = true) -> [String] {
        var asked: [String] = []
        PairedHostRegistry.migrateLegacy(in: defaults) { hostId in
            asked.append(hostId)
            return credentialMoves
        }
        return asked
    }

    // MARK: - The one paired computer becomes the first of the list

    // The fingerprint is the identity that survives re-pairing, so the
    // migrated record must keep it rather than invent a new one.
    @Test func theOneComputerFromBeforeBecomesTheFirstOfTheList() throws {
        let defaults = try defaults()
        seedLegacy(defaults)
        migrate(defaults)
        #expect(PairedHostRegistry.load(from: defaults).map(\.id) == ["fp-1"])
    }

    @Test func theMigratedComputerKeepsTheAddressItWasReachedAt() throws {
        let defaults = try defaults()
        seedLegacy(defaults)
        migrate(defaults)
        #expect(PairedHostRegistry.load(from: defaults).first?.address == "https://studio.tailnet.ts.net")
    }

    @Test func theCredentialIsAskedToMoveUnderTheMigratedComputersId() throws {
        let defaults = try defaults()
        seedLegacy(defaults)
        #expect(migrate(defaults) == ["fp-1"])
    }

    // A DEBUG host was typed in and never paired, so its address is all the
    // identity it has.
    @Test func aComputerTypedByAddressMigratesUnderThatAddress() throws {
        let defaults = try defaults()
        seedLegacy(defaults, record: false)
        migrate(defaults)
        #expect(PairedHostRegistry.load(from: defaults).map(\.id) == ["address:https://studio.tailnet.ts.net"])
    }

    @Test func theOldKeysAreGoneOnceTheListIsWritten() throws {
        let defaults = try defaults()
        seedLegacy(defaults)
        migrate(defaults)
        #expect(defaults.string(forKey: PairedHostRegistry.legacyAddressKey) == nil)
    }

    // MARK: - Nothing is lost when it cannot finish

    // First launch before the phone is unlocked: leave everything as it is
    // and let the next launch try again, rather than stranding the token.
    @Test func aKeychainThatCannotAnswerYetLeavesTheOldAddressForNextLaunch() throws {
        let defaults = try defaults()
        seedLegacy(defaults, record: false)
        migrate(defaults, credentialMoves: false)
        #expect(defaults.string(forKey: PairedHostRegistry.legacyAddressKey) == "https://studio.tailnet.ts.net")
    }

    @Test func aKeychainThatCannotAnswerYetWritesNoList() throws {
        let defaults = try defaults()
        seedLegacy(defaults, record: false)
        migrate(defaults, credentialMoves: false)
        #expect(PairedHostRegistry.load(from: defaults).isEmpty)
    }

    // MARK: - A phone that has already moved on

    @Test func aPhoneThatAlreadyHasAListKeepsTheComputersOnIt() throws {
        let defaults = try defaults()
        PairedHostRegistry.save([Fixtures.pairedHost(id: "fp-2")], to: defaults)
        seedLegacy(defaults, record: false)
        migrate(defaults)
        #expect(PairedHostRegistry.load(from: defaults).map(\.id) == ["fp-2"])
    }

    @Test func aPhoneThatAlreadyHasAListIsNotAskedToMoveACredentialAgain() throws {
        let defaults = try defaults()
        PairedHostRegistry.save([Fixtures.pairedHost(id: "fp-2")], to: defaults)
        seedLegacy(defaults, record: false)
        #expect(migrate(defaults).isEmpty)
    }

    @Test func aPhoneWithNothingToMigrateStillClearsTheOldKeys() throws {
        let defaults = try defaults()
        seedLegacy(defaults, address: "  ", record: false)
        migrate(defaults)
        #expect(defaults.string(forKey: PairedHostRegistry.legacyAddressKey) == nil)
    }

    // MARK: - The list itself

    @Test func aComputerPairedAgainReplacesItsRecordInPlace() throws {
        let defaults = try defaults()
        PairedHostRegistry.upsert(Fixtures.pairedHost(id: "fp-1"), in: defaults)
        PairedHostRegistry.upsert(Fixtures.pairedHost(id: "fp-2"), in: defaults)
        PairedHostRegistry.upsert(Fixtures.pairedHost(id: "fp-1", alias: "Studio"), in: defaults)
        #expect(PairedHostRegistry.load(from: defaults).map(\.alias) == ["Studio", nil])
    }
}
