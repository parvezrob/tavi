import Foundation
@testable import Tavi
import Testing

// One computer's live mirror (#50, #105): what the host pushed, stamped
// with when this phone saw it and smoothed so a card does not flicker,
// plus the routes the sheets borrow from it. Driven through a scripted
// socket and a scripted host, so nothing here opens a connection.
@MainActor
struct AgentDirectoryTests {
    private static let address = "https://studio.tailnet.ts.net"

    private static let reposAnswer = #"""
    {"repos":[{"root":"/repo","name":"repo","defaultBranch":"main","worktrees":[
      {"path":"/repo","branch":"main","head":"a1b2c3d","isMain":true,"dirty":2,
       "ahead":1,"behind":0,"locked":false,"prunable":false}]}]}
    """#

    private static let projectsAnswer = #"""
    {"recent":[{"path":"/repo","name":"repo","active":true,"withinRoots":true}],
     "workspaces":[],"roots":["/Users/dev/Projects"],
     "agents":[{"kind":"claude","label":"Claude Code","installed":true}]}
    """#

    private func directory(
        sockets: [FakeEventsSocket] = [],
        host: StubHost = StubHost(),
        credential: String = "secret",
        address: String = AgentDirectoryTests.address
    ) -> AgentDirectory {
        let directory = AgentDirectory(transport: host.transport, makeSocket: FakeSockets(sockets).make)
        directory.configure(hostId: "fp-1", hostText: address, credential: credential)
        return directory
    }

    // MARK: - What the host pushed

    @Test func theSnapshotBecomesTheAgentsTheHomeShows() async throws {
        let directory = directory(sockets: [FakeEventsSocket(.frame(Fixtures.agentsFrame()), .quiet)])
        defer { directory.stop() }
        try await waitUntil { directory.agents.map(\.id) == ["pane-1"] }
    }

    @Test func theSnapshotSaysWhetherThisComputerCanRunAgentsAtAll() async throws {
        let directory = directory(sockets: [FakeEventsSocket(.frame(Fixtures.agentsFrame(available: false)), .quiet)])
        defer { directory.stop() }
        try await waitUntil { directory.hasLoaded }
        #expect(directory.available == false)
    }

    // Two computers can each have a pane called "pane-1" (#50), so every
    // agent carries the computer it runs on.
    @Test func everyAgentIsStampedWithTheComputerItRunsOn() async throws {
        let directory = directory(sockets: [FakeEventsSocket(.frame(Fixtures.agentsFrame()), .quiet)])
        defer { directory.stop() }
        try await waitUntil { !directory.agents.isEmpty }
        #expect(directory.agents.first?.hostId == "fp-1")
    }

    @Test func theHeaderReadsItsHealthFromTheLinkBehindIt() async throws {
        let directory = directory(sockets: [FakeEventsSocket(.frame(Fixtures.agentsFrame()), .quiet)])
        defer { directory.stop() }
        try await waitUntil { directory.health == .live }
    }

    // MARK: - Freshness this phone actually witnessed

    @Test func everyAgentIsStampedWithWhenThisPhoneSawItsStatus() async throws {
        let directory = directory(sockets: [FakeEventsSocket(.frame(Fixtures.agentsFrame()), .quiet)])
        defer { directory.stop() }
        try await waitUntil { !directory.agents.isEmpty }
        #expect(directory.statusObservedAt["pane-1"] != nil)
    }

    // A snapshot that repeats what is already on screen must not restart
    // the clock: "3m ago" would reset to "now" on every reconnect.
    @Test func aStatusThatDidNotChangeKeepsTheMomentThisPhoneFirstSawIt() async throws {
        let directory = directory(sockets: [
            FakeEventsSocket(.frame(Fixtures.agentsFrame()), .drop),
            FakeEventsSocket(.frame(Fixtures.agentsFrame(available: false)), .quiet),
        ])
        defer { directory.stop() }
        try await waitUntil { !directory.agents.isEmpty }
        let first = directory.statusObservedAt["pane-1"]
        try await waitUntil(10) { directory.available == false }
        #expect(directory.statusObservedAt["pane-1"] == first)
    }

    @Test func aStatusThatChangedIsStampedWithTheMomentItChanged() async throws {
        let directory = directory(sockets: [
            FakeEventsSocket(.frame(Fixtures.agentsFrame(status: "idle")), .drop),
            FakeEventsSocket(.frame(Fixtures.agentsFrame(status: "working")), .quiet),
        ])
        defer { directory.stop() }
        try await waitUntil { !directory.agents.isEmpty }
        let first = try #require(directory.statusObservedAt["pane-1"])
        try await waitUntil(10) { directory.agents.first?.status == "working" }
        #expect((directory.statusObservedAt["pane-1"] ?? first) > first)
    }

    // MARK: - Through the smoother

    // A step up is news the home shows at once; the held step down is the
    // smoother's own contract, tested where it lives.
    @Test func aStatusSteppingUpShowsAtOnce() async throws {
        let socket = FakeEventsSocket(
            .frame(Fixtures.agentsFrame(status: "idle")),
            .frame(Fixtures.agentsFrame(status: "blocked")),
            .quiet
        )
        let directory = directory(sockets: [socket])
        defer { directory.stop() }
        try await waitUntil { directory.agents.first?.status == "blocked" }
    }

    // MARK: - Revoked

    @Test func aComputerThatRevokedThisPhoneShowsNoAgentsAndSaysToPairItAgain() async throws {
        let directory = directory(
            sockets: [FakeEventsSocket(.frame(Fixtures.agentsFrame()), .drop)],
            host: StubHost(routing: ["GET /api/host": .json(401, #"{"error":"Unauthorized."}"#)])
        )
        defer { directory.stop() }
        try await waitUntil(10) { directory.health == .revoked }
        #expect(directory.agents.isEmpty)
        #expect(directory.reason == "This iPhone is no longer paired with this computer. Pair it again to reconnect.")
    }

    // MARK: - Nothing to connect with

    @Test func aComputerWhoseCredentialIsGoneSaysToPairItAgain() {
        let directory = directory(credential: "")
        defer { directory.stop() }
        #expect(directory.reason == "Tavi no longer has a credential for this computer. Pair it again to reconnect.")
    }

    @Test func aComputerWhoseAddressIsNoLongerValidSaysSoInItsOwnWords() {
        let directory = directory(address: "not a host address")
        defer { directory.stop() }
        #expect(directory.reason == "This computer's address is not valid any more. Pair it again to reconnect.")
    }

    // The repos poll's gate, and the sheets' doors: with no credential
    // there is no route to ask, so nothing is asked of the host at all.
    @Test func aComputerWhoseCredentialIsGoneHandsOutNoRoutesAtAll() {
        let directory = directory(credential: "")
        defer { directory.stop() }
        #expect(directory.isConfigured == false)
        #expect(directory.filesClient == nil)
        #expect(directory.previewClient == nil)
    }

    @Test func switchingToAnotherComputerShowsNoneOfTheLastOnesAgents() async throws {
        let directory = directory(sockets: [FakeEventsSocket(.frame(Fixtures.agentsFrame()), .quiet)])
        defer { directory.stop() }
        try await waitUntil { !directory.agents.isEmpty }
        directory.configure(hostId: "fp-2", hostText: Self.address, credential: "secret")
        #expect(directory.agents.isEmpty)
    }

    // MARK: - The repositories poll

    @Test func theRepositoriesTheHostListedBecomeTheWorktreesBehindTheCards() async {
        let directory = directory(host: StubHost(routing: ["GET /api/repos": .json(200, Self.reposAnswer)]))
        defer { directory.stop() }
        await directory.refreshRepos()
        #expect(directory.repos.map(\.name) == ["repo"])
    }

    // MARK: - The routes the sheets borrow

    @Test func theDirectoryHandsOutFileRoutesForItsOwnComputer() {
        let directory = directory()
        defer { directory.stop() }
        #expect(directory.filesClient != nil)
    }

    // The directory is the only door to this computer: callers get answers,
    // never the credential behind them.
    @Test func theDirectoryForwardsTheProjectsTheHostListed() async {
        let directory = directory(host: StubHost(routing: ["GET /api/projects": .json(200, Self.projectsAnswer)]))
        defer { directory.stop() }
        guard case let .catalog(catalog) = await directory.fetchProjects() else {
            Issue.record("expected a catalog")
            return
        }
        #expect(catalog.recent.map(\.path) == ["/repo"])
    }

    @Test func theDirectoryForwardsTheHostsOwnRefusalToStartAnAgent() async {
        let directory = directory(host: StubHost(routing: [
            "POST /api/herdr/tabs": .json(403, #"{"error":"That folder is outside your project roots."}"#),
        ]))
        defer { directory.stop() }
        let outcome = await directory.createTab(agent: "claude", cwd: "/elsewhere")
        #expect(outcome == .failure("That folder is outside your project roots."))
    }
}
