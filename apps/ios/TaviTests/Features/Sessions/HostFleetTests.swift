import Foundation
@testable import Tavi
import Testing

// The book of paired computers (#50, #105): the only writer of the list
// and of a host's credential, and the owner of one live mirror per host.
// Driven against a scratch defaults suite, a credential store that is not
// the Keychain, and directories whose transport is a scripted host.
@MainActor
@Suite(.serialized)
struct HostFleetTests {
    // The Keychain as HostFleet uses it, in memory.
    private final class Credentials: HostCredentialStoring {
        var stored: [String: String] = [:]
        var legacyMoves: [String] = []

        func load(hostId: String) -> String { stored[hostId] ?? "" }
        func save(_ credential: String, hostId: String) { stored[hostId] = credential }
        func delete(hostId: String) { stored[hostId] = nil }
        func deleteAll() { stored = [:] }
        func migrateLegacyCredential(toHostId hostId: String) -> Bool {
            legacyMoves.append(hostId)
            return true
        }
    }

    private static let suiteName = "tavi.tests.fleet"

    private func fleet(_ credentials: Credentials) throws -> (HostFleet, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        return (makeFleet(on: defaults, credentials), defaults)
    }

    private func makeFleet(on defaults: UserDefaults, _ credentials: Credentials) -> HostFleet {
        HostFleet(defaults: defaults, credentials: credentials) {
            AgentDirectory(transport: StubHost().transport, makeSocket: FakeSockets().make)
        }
    }

    // MARK: - Adding

    @Test func pairingAComputerPutsItOnTheList() throws {
        let (fleet, _) = try fleet(Credentials())
        defer { fleet.stop() }
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-1")
        #expect(fleet.hosts.map(\.id) == ["fp-1"])
    }

    // A credential is shell access, so exactly one place writes it.
    @Test func pairingAComputerStoresItsCredentialUnderItsOwnId() throws {
        let credentials = Credentials()
        let (fleet, _) = try fleet(credentials)
        defer { fleet.stop() }
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-1")
        #expect(credentials.stored["fp-1"] == "token-1")
    }

    @Test func pairingTheSameComputerAgainKeepsItsPlaceInTheList() throws {
        let (fleet, _) = try fleet(Credentials())
        defer { fleet.stop() }
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-1")
        fleet.add(Fixtures.pairedHost(id: "fp-2"), credential: "token-2")
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-3")
        #expect(fleet.hosts.map(\.id) == ["fp-1", "fp-2"])
    }

    @Test func pairingTheSameComputerAgainReplacesItsCredential() throws {
        let credentials = Credentials()
        let (fleet, _) = try fleet(credentials)
        defer { fleet.stop() }
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-1")
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-2")
        #expect(credentials.stored["fp-1"] == "token-2")
    }

    // MARK: - One mirror per computer

    @Test func everyPairedComputerGetsItsOwnMirror() throws {
        let (fleet, _) = try fleet(Credentials())
        defer { fleet.stop() }
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-1")
        fleet.add(Fixtures.pairedHost(id: "fp-2"), credential: "token-2")
        #expect(fleet.directory(for: "fp-1") !== fleet.directory(for: "fp-2"))
    }

    @Test func aMirrorKnowsWhichComputerItIsMirroring() throws {
        let (fleet, _) = try fleet(Credentials())
        defer { fleet.stop() }
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-1")
        #expect(fleet.directory(for: "fp-1")?.hostId == "fp-1")
    }

    @Test func theEntriesTheHomeReadsFollowPairingOrder() throws {
        let (fleet, _) = try fleet(Credentials())
        defer { fleet.stop() }
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-1")
        fleet.add(Fixtures.pairedHost(id: "fp-2"), credential: "token-2")
        #expect(fleet.entries.map(\.id) == ["fp-1", "fp-2"])
    }

    // MARK: - Renaming

    @Test func renamingAComputerChangesWhatThePhoneCallsIt() throws {
        let (fleet, _) = try fleet(Credentials())
        defer { fleet.stop() }
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-1")
        fleet.rename(hostId: "fp-1", alias: "Studio")
        #expect(fleet.host(for: "fp-1")?.displayName == "Studio")
    }

    @Test func aBlankAliasGoesBackToTheNameTheComputerReported() throws {
        let (fleet, _) = try fleet(Credentials())
        defer { fleet.stop() }
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-1")
        fleet.rename(hostId: "fp-1", alias: "Studio")
        fleet.rename(hostId: "fp-1", alias: "  ")
        #expect(fleet.host(for: "fp-1")?.displayName == "studio-mac")
    }

    // Same computer, new label: the stream behind it must not be restarted.
    @Test func renamingAComputerLeavesItsMirrorRunning() throws {
        let (fleet, _) = try fleet(Credentials())
        defer { fleet.stop() }
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-1")
        let mirror = fleet.directory(for: "fp-1")
        fleet.rename(hostId: "fp-1", alias: "Studio")
        #expect(fleet.directory(for: "fp-1") === mirror)
    }

    @Test func renamingAComputerThatIsNotPairedChangesNothing() throws {
        let (fleet, _) = try fleet(Credentials())
        defer { fleet.stop() }
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-1")
        fleet.rename(hostId: "fp-9", alias: "Studio")
        #expect(fleet.hosts == [Fixtures.pairedHost(id: "fp-1")])
    }

    // MARK: - Forgetting

    @Test func forgettingAComputerTakesItOffTheList() throws {
        let (fleet, _) = try fleet(Credentials())
        defer { fleet.stop() }
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-1")
        fleet.add(Fixtures.pairedHost(id: "fp-2"), credential: "token-2")
        fleet.remove(hostId: "fp-1")
        #expect(fleet.hosts.map(\.id) == ["fp-2"])
    }

    @Test func forgettingAComputerRemovesItsCredential() throws {
        let credentials = Credentials()
        let (fleet, _) = try fleet(credentials)
        defer { fleet.stop() }
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-1")
        fleet.remove(hostId: "fp-1")
        #expect(credentials.stored["fp-1"] == nil)
    }

    @Test func forgettingOneComputerLeavesTheOthersCredentialAlone() throws {
        let credentials = Credentials()
        let (fleet, _) = try fleet(credentials)
        defer { fleet.stop() }
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-1")
        fleet.add(Fixtures.pairedHost(id: "fp-2"), credential: "token-2")
        fleet.remove(hostId: "fp-1")
        #expect(credentials.stored["fp-2"] == "token-2")
    }

    // The mirror goes with the host: nothing keeps polling a computer this
    // phone is no longer paired with.
    @Test func forgettingAComputerTakesItsMirrorWithIt() throws {
        let (fleet, _) = try fleet(Credentials())
        defer { fleet.stop() }
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-1")
        fleet.remove(hostId: "fp-1")
        #expect(fleet.directory(for: "fp-1") == nil)
    }

    @Test func forgettingOneComputerLeavesTheOthersMirrorRunning() throws {
        let (fleet, _) = try fleet(Credentials())
        defer { fleet.stop() }
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-1")
        fleet.add(Fixtures.pairedHost(id: "fp-2"), credential: "token-2")
        fleet.remove(hostId: "fp-1")
        #expect(fleet.directory(for: "fp-2") != nil)
    }

    @Test func aFullResetLeavesNoPairedComputer() throws {
        let (fleet, _) = try fleet(Credentials())
        defer { fleet.stop() }
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-1")
        fleet.removeAll()
        #expect(fleet.isConfigured == false)
    }

    @Test func aFullResetLeavesNoCredentialBehind() throws {
        let credentials = Credentials()
        let (fleet, _) = try fleet(credentials)
        defer { fleet.stop() }
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-1")
        fleet.add(Fixtures.pairedHost(id: "fp-2"), credential: "token-2")
        fleet.removeAll()
        #expect(credentials.stored.isEmpty)
    }

    // MARK: - Across launches

    // An entry needs both halves, so this says the computers came back in
    // pairing order and each one got its mirror again.
    @Test func everyComputerComesBackWithItsMirrorInPairingOrder() throws {
        let credentials = Credentials()
        let (fleet, defaults) = try fleet(credentials)
        fleet.add(Fixtures.pairedHost(id: "fp-1"), credential: "token-1")
        fleet.add(Fixtures.pairedHost(id: "fp-2"), credential: "token-2")
        fleet.stop()

        let relaunched = makeFleet(on: defaults, credentials)
        defer { relaunched.stop() }
        relaunched.load()
        #expect(relaunched.entries.map(\.id) == ["fp-1", "fp-2"])
    }

    // The one-host→many-hosts move (#50) is retried on every launch until
    // the Keychain can answer, so `load` is where it is attempted.
    @Test func everyLaunchOffersTheOneHostMigrationTheCredentialItNeeds() throws {
        let credentials = Credentials()
        let (fleet, defaults) = try fleet(credentials)
        defer { fleet.stop() }
        defaults.set("https://studio.tailnet.ts.net", forKey: PairedHostRegistry.legacyAddressKey)
        fleet.load()
        #expect(credentials.legacyMoves == ["address:https://studio.tailnet.ts.net"])
    }
}
