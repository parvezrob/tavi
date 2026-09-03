import Foundation
@testable import Tavi
import Testing

struct HomeGroupingTests {
    private func host(_ id: String, name: String, agents: [AgentSummary], health: HostHealth = .live, repos: [RepoInfo] = []) -> HomeHostInput {
        HomeHostInput(id: id, name: name, agents: agents.map { var a = $0; a.hostId = id; return a }, health: health, repos: repos)
    }

    private func worktree(
        _ path: String,
        branch: String? = "main",
        isMain: Bool = true,
        dirty: Int = 0,
        ahead: Int = 0,
        behind: Int = 0,
        locked: Bool = false,
        pullRequest: Int? = nil
    ) -> WorktreeInfo {
        WorktreeInfo(
            path: path, branch: branch, head: "abc1234", isMain: isMain, dirty: dirty, ahead: ahead, behind: behind,
            locked: locked, prunable: false,
            pullRequest: pullRequest.map { PullRequestRef(number: $0, url: "https://github.com/x/y/pull/\($0)") }
        )
    }

    private func repo(_ root: String, _ worktrees: [WorktreeInfo]) -> RepoInfo {
        RepoInfo(root: root, name: URL(fileURLWithPath: root).lastPathComponent, defaultBranch: "main", worktrees: worktrees)
    }

    @Test
    func groupsAgentsByFolderAndKeepsNeedsYouAboveEverything() {
        let layout = HomeGrouping.layout(hosts: [
            host("mac", name: "MacBook", agents: [
                Fixtures.agentSummary(id: "a", status: "working", cwd: "/Users/dev/Projects/api"),
                Fixtures.agentSummary(id: "b", status: "blocked", cwd: "/Users/dev/Projects/web"),
                Fixtures.agentSummary(id: "c", status: "done", cwd: "/Users/dev/Projects/api"),
                Fixtures.agentSummary(id: "d", status: "idle", cwd: "/Users/dev/Projects/web"),
            ]),
        ])

        #expect(layout.needsYou.map(\.id) == ["b"])
        #expect(layout.computers.map(\.name) == ["MacBook"])
        let projects = layout.computers[0].projects
        #expect(projects.map(\.name) == ["api", "web"])
        #expect(projects[0].active.map(\.id) == ["a"])
        #expect(projects[0].recent.map(\.id) == ["c"])
        // The blocked agent is rendered at the top only; its folder counts
        // it so the header neither repeats it nor loses it.
        #expect(projects[1].needsYou.map(\.id) == ["b"])
        #expect(projects[1].active.isEmpty)
        #expect(projects[1].recent.map(\.id) == ["d"])
        #expect(projects[1].agentCount == 2)
    }

    @Test
    func aFolderWhoseOnlyAgentIsBlockedKeepsItsHeader() {
        let projects = HomeGrouping.group([
            Fixtures.agentSummary(id: "b", status: "blocked", cwd: "/p/web"),
            Fixtures.agentSummary(id: "c", status: "blocked", cwd: "/p/web"),
        ])

        #expect(projects.map(\.id) == ["/p/web"])
        #expect(projects[0].needsYou.count == 2)
        #expect(projects[0].active.isEmpty && projects[0].recent.isEmpty)
    }

    @Test
    func projectsAreOrderedByNameRegardlessOfStatus() {
        let projects = HomeGrouping.group([
            Fixtures.agentSummary(id: "1", status: "done", cwd: "/p/zeta"),
            Fixtures.agentSummary(id: "2", status: "idle", cwd: "/p/Alpha"),
            Fixtures.agentSummary(id: "3", status: "working", cwd: "/p/mid"),
            Fixtures.agentSummary(id: "4", status: "done", cwd: "/p/beta"),
        ])

        #expect(projects.map(\.name) == ["Alpha", "beta", "mid", "zeta"])
    }

    @Test
    func trailingSlashesDoNotSplitAFolderInTwo() {
        let projects = HomeGrouping.group([
            Fixtures.agentSummary(id: "1", status: "working", cwd: "/p/api//"),
            Fixtures.agentSummary(id: "2", status: "done", cwd: "/p/api"),
        ])

        #expect(projects.count == 1)
        #expect(projects[0].path == "/p/api")
        #expect(projects[0].active.map(\.id) == ["1"])
        #expect(projects[0].recent.map(\.id) == ["2"])
    }

    @Test
    func agentsInsideAProjectKeepTheHostOrder() {
        let projects = HomeGrouping.group([
            Fixtures.agentSummary(id: "late", status: "done", cwd: "/p/api"),
            Fixtures.agentSummary(id: "early", status: "done", cwd: "/p/api"),
        ])

        #expect(projects[0].recent.map(\.id) == ["late", "early"])
    }

    @Test
    func rootHomeAndOddPathsStillGetAName() {
        #expect(HomeGrouping.projectName(of: "/") == "/")
        #expect(HomeGrouping.projectName(of: "/Users/dev/Projects/tavi") == "tavi")
        #expect(HomeGrouping.projectName(of: "/Users/dev") == "Home")
        #expect(HomeGrouping.projectName(of: "/home/dev/") == "Home")
        #expect(HomeGrouping.projectName(of: "") == "Unknown folder")
        #expect(HomeGrouping.projectPath(of: "/") == "/")
    }

    @Test
    func onlyNeedsYouIsNotAnEmptyHome() {
        let layout = HomeGrouping.layout(hosts: [
            host("mac", name: "MacBook", agents: [Fixtures.agentSummary(id: "b", status: "blocked", cwd: "/p/web")]),
        ])

        // The folder keeps its header (it counts the waiting agent); the
        // agent itself is rendered only in the flat needs-you list.
        #expect(layout.computers.count == 1)
        #expect(layout.computers[0].projects.map(\.needsYou.count) == [1])
        #expect(!layout.isEmpty)
        // An idle computer still has its header row; the home is "empty"
        // only in the sense that there is no agent anywhere.
        let idle = HomeGrouping.layout(hosts: [host("mac", name: "MacBook", agents: [])])
        #expect(idle.isEmpty)
        #expect(idle.computers.map(\.name) == ["MacBook"])
    }

    // #50: several computers, each its own group in pairing order; waiting
    // work from every computer leads, in the same order, so an agent on the
    // second machine never hides under the first one's group.
    @Test
    func severalComputersKeepPairingOrderAndPoolNeedsYou() {
        let layout = HomeGrouping.layout(hosts: [
            host("mac", name: "MacBook", agents: [
                Fixtures.agentSummary(id: "1", status: "working", cwd: "/Users/dev/api"),
                Fixtures.agentSummary(id: "2", status: "done", cwd: "/Users/dev/api"),
            ]),
            host("ubuntu", name: "ubuntu", agents: [
                Fixtures.agentSummary(id: "1", status: "blocked", cwd: "/home/dev/api"),
                Fixtures.agentSummary(id: "9", status: "idle", cwd: "/home/dev/web"),
            ], health: .stale),
            host("asleep", name: "Studio", agents: [], health: .offline),
        ])

        #expect(layout.computers.map(\.name) == ["MacBook", "ubuntu", "Studio"])
        #expect(layout.computers.map(\.health) == [.live, .stale, .offline])
        // Same pane id on two computers: distinct targets, distinct cards.
        #expect(layout.needsYou.map(\.target) == [AgentTarget(hostId: "ubuntu", paneId: "1")])
        #expect(layout.computers[0].projects.flatMap(\.active).map(\.target) == [AgentTarget(hostId: "mac", paneId: "1")])
        let projects = layout.computers.flatMap(\.projects)
        let everyAgent = projects.flatMap { $0.needsYou + $0.active + $0.recent }
        let identities = Set(everyAgent.map(\.cardIdentity))
        #expect(identities.count == 4)
        #expect(layout.computers[1].projects.map(\.name) == ["api", "web"])
        #expect(layout.computers[2].projects.isEmpty)
        #expect(layout.computers[2].agentCount == 0)
        #expect(!layout.isEmpty)
    }

    // #74: an agent under a known worktree files under its repository's
    // card, in that worktree's group; every worktree the repository has is
    // shown, agents or not; a folder no repo claims renders as before.
    @Test
    func agentsFileUnderTheirRepositoryAndWorktree() {
        let tavi = repo("/Users/dev/Projects/tavi", [
            worktree("/Users/dev/Projects/tavi", branch: "main"),
            worktree("/Users/dev/Projects/tavi-59-demo", branch: "demo/59", isMain: false, dirty: 1, ahead: 1),
            worktree("/Users/dev/Projects/tavi-idle", branch: "idle/branch", isMain: false),
        ])
        let projects = HomeGrouping.group([
            Fixtures.agentSummary(id: "1", status: "working", cwd: "/Users/dev/Projects/tavi/apps/ios"),
            Fixtures.agentSummary(id: "2", status: "done", cwd: "/Users/dev/Projects/tavi-59-demo"),
            Fixtures.agentSummary(id: "3", status: "idle", cwd: "/Users/dev/Projects/plain"),
        ], repos: [tavi])

        #expect(projects.map(\.name) == ["plain", "tavi"])
        let card = projects[1]
        #expect(card.path == "/Users/dev/Projects/tavi")
        #expect(card.isRepository)
        #expect(card.worktrees.map(\.info.branch) == ["main", "demo/59", "idle/branch"])
        #expect(card.worktrees[0].active.map(\.id) == ["1"])
        #expect(card.worktrees[1].recent.map(\.id) == ["2"])
        #expect(card.worktrees[2].agentCount == 0)
        #expect(card.agentCount == 2)
        #expect(card.active.isEmpty && card.recent.isEmpty)
        // The card has nothing at its top level but must still render:
        // its rows live inside the worktrees.
        #expect(card.hasRows)
        let plain = projects[0]
        #expect(!plain.isRepository)
        #expect(plain.recent.map(\.id) == ["3"])
    }

    // Two repositories reporting one root (#76 edge) are one card with the
    // worktrees pooled; nothing renders twice under one identity.
    @Test
    func twoRepositoriesWithOneRootAreOneCard() {
        let first = repo("/p/tavi", [worktree("/p/tavi")])
        let second = repo("/p/tavi", [worktree("/p/tavi"), worktree("/p/tavi-x", branch: "x", isMain: false)])
        let projects = HomeGrouping.group([Fixtures.agentSummary(id: "1", status: "working", cwd: "/p/tavi-x/apps")], repos: [first, second])
        #expect(projects.count == 1)
        #expect(projects[0].path == "/p/tavi")
        #expect(projects[0].worktrees.map(\.info.branch) == ["main", "x"])
        #expect(projects[0].worktrees[1].active.map(\.id) == ["1"])
        #expect(HomeGrouping.mergedByRoot([first, second]).count == 1)
        #expect(HomeGrouping.mergedByRoot([first, first]).first?.worktrees.count == 1)
    }

    // A repository whose root is not among its worktrees (#76 edge): an
    // agent at that root rides on the card as a plain row, not as a
    // second card with the same path.
    @Test
    func anAgentAtARootThatIsNotAWorktreeRidesOnTheCard() {
        let odd = repo("/p/tavi", [worktree("/p/tavi-only", branch: "only", isMain: false)])
        let projects = HomeGrouping.group([
            Fixtures.agentSummary(id: "1", status: "working", cwd: "/p/tavi"),
            Fixtures.agentSummary(id: "2", status: "done", cwd: "/p/tavi-only"),
        ], repos: [odd])
        #expect(projects.count == 1)
        #expect(Set(projects.map(\.id)).count == projects.count)
        #expect(projects[0].active.map(\.id) == ["1"])
        #expect(projects[0].worktrees[0].recent.map(\.id) == ["2"])
        #expect(projects[0].agentCount == 2)
    }

    // An older host does not say whether a worktree is inside the roots;
    // it is assumed to be. A newer one says, and the phone keeps the word.
    @Test
    func withinRootsDefaultsToTrueWhenTheHostDoesNotSay() throws {
        let base = "\"path\":\"/w\",\"branch\":\"x\",\"head\":\"abc\",\"isMain\":false,\"dirty\":0,\"ahead\":0,\"behind\":0,\"locked\":false,\"prunable\":false,\"pullRequest\":null"
        let old = try JSONDecoder().decode(WorktreeInfo.self, from: Data("{\(base)}".utf8))
        #expect(old.withinRoots == true)
        let outside = try JSONDecoder().decode(WorktreeInfo.self, from: Data("{\(base),\"withinRoots\":false}".utf8))
        #expect(outside.withinRoots == false)
    }

    // A folder that merely shares a prefix with a worktree path is not
    // inside it: "/Users/dev/tavi-docs" must not match "/Users/dev/tavi".
    @Test
    func aFolderThatOnlySharesAPathPrefixIsNotInTheRepository() {
        let projects = HomeGrouping.group(
            [Fixtures.agentSummary(id: "1", status: "working", cwd: "/Users/dev/tavi-docs")],
            repos: [repo("/Users/dev/tavi", [worktree("/Users/dev/tavi")])]
        )
        #expect(!projects[0].isRepository)
        #expect(projects[0].path == "/Users/dev/tavi-docs")
    }

    // Two candidate worktrees, one nested under the other: the more
    // specific (longest) containing path wins.
    @Test
    func theMostSpecificContainingWorktreeWins() {
        let projects = HomeGrouping.group(
            [Fixtures.agentSummary(id: "1", status: "working", cwd: "/Users/dev/tavi/nested/deep")],
            repos: [repo("/Users/dev/tavi", [
                worktree("/Users/dev/tavi", branch: "main"),
                worktree("/Users/dev/tavi/nested", branch: "fix/foo", isMain: false),
            ])]
        )
        #expect(projects[0].worktrees[1].active.map(\.id) == ["1"])
        #expect(projects[0].worktrees[0].agentCount == 0)
    }

    // A waiting agent inside a worktree is counted by the card and the
    // computer, and rendered only in the flat needs-you list.
    @Test
    func aWaitingAgentInAWorktreeIsCountedNotRepeated() {
        let layout = HomeGrouping.layout(hosts: [
            host("mac", name: "MacBook", agents: [Fixtures.agentSummary(id: "b", status: "blocked", cwd: "/p/tavi/apps/host")],
                 repos: [repo("/p/tavi", [worktree("/p/tavi")])]),
        ])
        #expect(layout.needsYou.map(\.id) == ["b"])
        #expect(layout.computers[0].waitingCount == 1)
        #expect(layout.computers[0].projects[0].needsYouCount == 1)
        #expect(layout.computers[0].projects[0].worktrees[0].needsYou.map(\.id) == ["b"])
    }

    // A repository card whose only agent is waiting above still renders —
    // its worktree groups are content in their own right (review,
    // 2026-09-02); a plain folder in the same state does not.
    @Test
    func aRepositoryCardStaysWhileItsOnlyAgentWaits() {
        let projects = HomeGrouping.group(
            [Fixtures.agentSummary(id: "b", status: "blocked", cwd: "/p/tavi"), Fixtures.agentSummary(id: "c", status: "blocked", cwd: "/p/plain")],
            repos: [repo("/p/tavi", [worktree("/p/tavi"), worktree("/p/tavi-x", branch: "x", isMain: false)])]
        )
        #expect(projects.first { $0.name == "tavi" }?.hasRows == true)
        #expect(projects.first { $0.name == "plain" }?.hasRows == false)
    }

    // The host compares paths case- and Unicode-normalisation-insensitively
    // (macOS APFS); so must the phone, or a folder typed as ~/projects/Tavi
    // sits beside the ~/Projects/tavi card it belongs in.
    @Test
    func containmentIgnoresCaseAndUnicodeForm() {
        let decomposed = "/Users/dev/Caf\u{0065}\u{0301}/apps"
        let projects = HomeGrouping.group(
            [Fixtures.agentSummary(id: "1", status: "working", cwd: "/users/DEV/tavi/apps/ios"), Fixtures.agentSummary(id: "2", status: "idle", cwd: decomposed)],
            repos: [
                repo("/Users/dev/tavi", [worktree("/Users/dev/tavi")]),
                repo("/Users/dev/Caf\u{00E9}", [worktree("/Users/dev/Caf\u{00E9}")]),
            ]
        )
        #expect(projects.map(\.name).sorted() == ["Caf\u{00E9}", "tavi"])
        #expect(projects.first { $0.name == "tavi" }?.worktrees[0].active.map(\.id) == ["1"])
        #expect(projects.first { $0.name == "Caf\u{00E9}" }?.worktrees[0].recent.map(\.id) == ["2"])
    }

    @Test
    func worktreeSummaryCoversEveryState() {
        #expect(worktree("/w", branch: "main").summary == "")
        #expect(WorktreeInfo(path: "/w", branch: "gone", head: "a", isMain: false, dirty: 0, ahead: 0, behind: 0, locked: false, prunable: true, pullRequest: nil).summary == "Folder missing")
        #expect(worktree("/w", branch: nil).title == "detached · abc1234")
        #expect(WorktreeInfo(path: "/w", branch: nil, head: "", isMain: false, dirty: 0, ahead: 0, behind: 0, locked: false, prunable: false, pullRequest: nil).title == "detached")
        #expect(worktree("/w", branch: "fix", dirty: 2, ahead: 3, behind: 1).summary == "↑3 ↓1 · 2 uncommitted")
        #expect(worktree("/w", branch: "fix", ahead: 2).summary == "↑2")
        #expect(worktree("/w", branch: "fix", dirty: 1, pullRequest: 48).summary == "PR #48 · 1 uncommitted")
        #expect(worktree("/w", branch: "fix", locked: true).summary == "locked")
    }

    @Test
    func computerSummaryIsOneLine() {
        let layout = HomeGrouping.layout(hosts: [
            host("mac", name: "MacBook Air", agents: [
                Fixtures.agentSummary(id: "1", status: "blocked", cwd: "/p/a"),
                Fixtures.agentSummary(id: "2", status: "working", cwd: "/p/a"),
                Fixtures.agentSummary(id: "3", status: "done", cwd: "/p/b"),
            ], health: .live),
            host("pc", name: "robin-PC", agents: [Fixtures.agentSummary(id: "1", status: "idle", cwd: "/p/a")]),
            host("off", name: "Studio", agents: [], health: .offline),
        ])
        let summaries = layout.computers.map(\.summary)
        #expect(summaries[0] == "Live · 3 agents · 1 waiting")
        #expect(summaries[1] == "Live · 1 agent")
        #expect(summaries[2] == "Offline")
        let live = HomeComputer(id: "x", name: "x", health: .live, latencyMilliseconds: 40, hasLoaded: true, available: true, reason: nil, projects: layout.computers[0].projects)
        #expect(live.summary == "Live · 40 ms · 3 agents · 1 waiting")
        #expect(live.isQuietlyIdle)
    }

    @Test
    func healthLabelSpeaksLatencyOnlyWhileLive() {
        #expect(HostHealth.live.label(latencyMilliseconds: 42) == "Live · 42 ms")
        #expect(HostHealth.live.label(latencyMilliseconds: nil) == "Live")
        #expect(HostHealth.stale.label(latencyMilliseconds: 42) == "Reconnecting")
        #expect(HostHealth.offline.label(latencyMilliseconds: 42) == "Offline")
        #expect(HostHealth.revoked.label(latencyMilliseconds: nil) == "Unpaired")
        #expect(HostHealth.connecting.label(latencyMilliseconds: nil) == "Connecting…")
    }

    @Test
    func computerNamePrefersThePairedNameThenTheAddress() {
        #expect(HomeGrouping.computerName(pairedName: "Parvez's MacBook Air", hostText: "https://x.ts.net") == "Parvez's MacBook Air")
        #expect(HomeGrouping.computerName(pairedName: "  ", hostText: "https://parvezs-macbook-air.tail.ts.net") == "parvezs-macbook-air")
        #expect(HomeGrouping.computerName(pairedName: nil, hostText: "https://192.168.1.5:8787") == "192.168.1.5")
        #expect(HomeGrouping.computerName(pairedName: nil, hostText: "my-mac.tailnet.ts.net") == "my-mac")
        #expect(HomeGrouping.computerName(pairedName: nil, hostText: "") == "Paired computer")
    }

    // Owner call 2026-09-02: waiting rows the phone cannot tell apart stack
    // into one; a real question, a name, another folder, or another
    // computer keeps its own row.
    @Test
    func stacksIndistinguishableWaitingAgentsAndKeepsDistinctOnesApart() {
        var blank1 = Fixtures.agentSummary(id: "a", status: "blocked", cwd: "/Users/dev"); blank1.hostId = "mac"
        var blank2 = Fixtures.agentSummary(id: "b", status: "blocked", cwd: "/Users/dev"); blank2.hostId = "mac"
        var asking = Fixtures.agentSummary(id: "c", status: "blocked", cwd: "/Users/dev"); asking.hostId = "mac"
        var otherFolder = Fixtures.agentSummary(id: "d", status: "blocked", cwd: "/Users/dev/Projects/api"); otherFolder.hostId = "mac"
        var otherHost = Fixtures.agentSummary(id: "e", status: "blocked", cwd: "/Users/dev"); otherHost.hostId = "pc"
        var named = Fixtures.agentSummary(id: "f", status: "blocked", cwd: "/Users/dev"); named.hostId = "mac"; named.tabLabel = "Redesign"
        var blank3 = Fixtures.agentSummary(id: "g", status: "blocked", cwd: "/Users/dev"); blank3.hostId = "mac"

        let groups = HomeGrouping.waitingGroups([blank1, blank2, asking, otherFolder, otherHost, named, blank3]) { agent in
            agent.id == "c" ? "Allow Bash(npm test)?" : nil
        }

        #expect(groups.map { $0.agents.map(\.id) } == [["a", "b", "g"], ["c"], ["d"], ["e"], ["f"]])
        #expect(groups[0].isStacked)
        #expect(groups[0].askingLine == nil)
        #expect(groups[1].askingLine == "Allow Bash(npm test)?")
        #expect(!groups[1].isStacked)
    }

    @Test
    func sameQuestionOnTwoPanesStacksToo() {
        var one = Fixtures.agentSummary(id: "a", status: "blocked", cwd: "/Users/dev/p"); one.hostId = "mac"
        var two = Fixtures.agentSummary(id: "b", status: "blocked", cwd: "/Users/dev/p"); two.hostId = "mac"
        let groups = HomeGrouping.waitingGroups([one, two]) { _ in "Continue? [y/N]" }
        #expect(groups.count == 1)
        #expect(groups[0].askingLine == "Continue? [y/N]")
    }
}
