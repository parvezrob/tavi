import Foundation
import Testing
@testable import Tavi

struct HomeGroupingTests {
    private func agent(
        _ id: String,
        status: String,
        cwd: String,
        agent: String = "claude"
    ) -> AgentSummary {
        AgentSummary(
            id: id,
            agent: agent,
            status: status,
            cwd: cwd,
            title: "",
            workspaceId: "ws",
            tabId: "tab-\(id)",
            focused: false
        )
    }

    private func host(_ id: String, name: String, agents: [AgentSummary], health: HostHealth = .live, worktrees: [WorktreeInfo] = []) -> HomeHostInput {
        HomeHostInput(id: id, name: name, agents: agents.map { var a = $0; a.hostId = id; return a }, health: health, worktrees: worktrees)
    }

    private func worktree(
        _ path: String,
        branch: String? = "main",
        isMain: Bool = true,
        dirty: Int = 0,
        ahead: Int = 0,
        behind: Int = 0,
        locked: Bool = false
    ) -> WorktreeInfo {
        WorktreeInfo(path: path, branch: branch, head: "abc1234", isMain: isMain, dirty: dirty, ahead: ahead, behind: behind, locked: locked, prunable: false)
    }

    @Test
    func groupsAgentsByFolderAndKeepsNeedsYouAboveEverything() {
        let layout = HomeGrouping.layout(hosts: [
            host("mac", name: "MacBook", agents: [
                agent("a", status: "working", cwd: "/Users/dev/Projects/api"),
                agent("b", status: "blocked", cwd: "/Users/dev/Projects/web"),
                agent("c", status: "done", cwd: "/Users/dev/Projects/api"),
                agent("d", status: "idle", cwd: "/Users/dev/Projects/web"),
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
            agent("b", status: "blocked", cwd: "/p/web"),
            agent("c", status: "blocked", cwd: "/p/web"),
        ])

        #expect(projects.map(\.id) == ["/p/web"])
        #expect(projects[0].needsYou.count == 2)
        #expect(projects[0].active.isEmpty && projects[0].recent.isEmpty)
    }

    @Test
    func projectsAreOrderedByNameRegardlessOfStatus() {
        let projects = HomeGrouping.group([
            agent("1", status: "done", cwd: "/p/zeta"),
            agent("2", status: "idle", cwd: "/p/Alpha"),
            agent("3", status: "working", cwd: "/p/mid"),
            agent("4", status: "done", cwd: "/p/beta"),
        ])

        #expect(projects.map(\.name) == ["Alpha", "beta", "mid", "zeta"])
    }

    @Test
    func trailingSlashesDoNotSplitAFolderInTwo() {
        let projects = HomeGrouping.group([
            agent("1", status: "working", cwd: "/p/api//"),
            agent("2", status: "done", cwd: "/p/api"),
        ])

        #expect(projects.count == 1)
        #expect(projects[0].path == "/p/api")
        #expect(projects[0].active.map(\.id) == ["1"])
        #expect(projects[0].recent.map(\.id) == ["2"])
    }

    @Test
    func agentsInsideAProjectKeepTheHostOrder() {
        let projects = HomeGrouping.group([
            agent("late", status: "done", cwd: "/p/api"),
            agent("early", status: "done", cwd: "/p/api"),
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
            host("mac", name: "MacBook", agents: [agent("b", status: "blocked", cwd: "/p/web")]),
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
                agent("1", status: "working", cwd: "/Users/dev/api"),
                agent("2", status: "done", cwd: "/Users/dev/api"),
            ]),
            host("ubuntu", name: "ubuntu", agents: [
                agent("1", status: "blocked", cwd: "/home/dev/api"),
                agent("9", status: "idle", cwd: "/home/dev/web"),
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

    // #59a: a project's folder carries its worktree state when the host
    // reported one for that path; an ordinary folder (no matching path in
    // GET /api/repos) renders exactly as before.
    @Test
    func projectsCarryWorktreeStateWhenTheHostReportsOne() {
        let layout = HomeGrouping.layout(hosts: [
            host("mac", name: "MacBook", agents: [
                agent("1", status: "working", cwd: "/Users/dev/Projects/app-fix-foo"),
                agent("2", status: "idle", cwd: "/Users/dev/Projects/plain"),
            ], worktrees: [
                worktree("/Users/dev/Projects/app-fix-foo", branch: "fix/foo", isMain: false, dirty: 2, ahead: 3, behind: 1),
                worktree("/Users/dev/Projects/app"),
            ]),
        ])

        let projects = layout.computers[0].projects
        let withWorktree = projects.first { $0.path == "/Users/dev/Projects/app-fix-foo" }
        #expect(withWorktree?.worktree?.branch == "fix/foo")
        #expect(withWorktree?.worktree?.summary == "fix/foo · +3/−1 · 2 uncommitted")

        let plain = projects.first { $0.path == "/Users/dev/Projects/plain" }
        #expect(plain?.worktree == nil)
    }

    // An agent's cwd is routinely *inside* a worktree, not at its root —
    // this repo's own layout (apps/ios, apps/host as separate agent
    // folders under one worktree) is the ordinary case. Containment, not
    // equality, must find the worktree.
    @Test
    func aProjectBelowAWorktreeRootStillFindsIt() {
        let projects = HomeGrouping.group(
            [agent("1", status: "working", cwd: "/Users/dev/tavi/apps/ios")],
            worktrees: [worktree("/Users/dev/tavi", branch: "main")]
        )
        #expect(projects[0].worktree?.branch == "main")
    }

    // A folder that merely shares a prefix with a worktree path is not
    // inside it: "/Users/dev/tavi-docs" must not match the worktree at
    // "/Users/dev/tavi".
    @Test
    func aFolderThatOnlySharesAPathPrefixDoesNotMatch() {
        let projects = HomeGrouping.group(
            [agent("1", status: "working", cwd: "/Users/dev/tavi-docs")],
            worktrees: [worktree("/Users/dev/tavi", branch: "main")]
        )
        #expect(projects[0].worktree == nil)
    }

    // Two candidate worktrees, one nested under the other: the more
    // specific (longest) containing path wins.
    @Test
    func theMostSpecificContainingWorktreeWins() {
        let projects = HomeGrouping.group(
            [agent("1", status: "working", cwd: "/Users/dev/tavi/nested/deep")],
            worktrees: [
                worktree("/Users/dev/tavi", branch: "main"),
                worktree("/Users/dev/tavi/nested", branch: "fix/foo"),
            ]
        )
        #expect(projects[0].worktree?.branch == "fix/foo")
    }

    @Test
    func worktreeSummaryCoversCleanDetachedAndLockedStates() {
        #expect(worktree("/w", branch: "main").summary == "main")
        #expect(worktree("/w", branch: nil).summary == "detached")
        #expect(worktree("/w", branch: "fix", ahead: 2, behind: 0).summary == "fix · +2/−0")
        #expect(worktree("/w", branch: "fix", locked: true).summary == "fix · locked")
    }

    @Test
    func computerSummaryIsOneLine() {
        let layout = HomeGrouping.layout(hosts: [
            host("mac", name: "MacBook Air", agents: [
                agent("1", status: "blocked", cwd: "/p/a"),
                agent("2", status: "working", cwd: "/p/a"),
                agent("3", status: "done", cwd: "/p/b"),
            ], health: .live),
            host("pc", name: "robin-PC", agents: [agent("1", status: "idle", cwd: "/p/a")]),
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
        var blank1 = agent("a", status: "blocked", cwd: "/Users/dev"); blank1.hostId = "mac"
        var blank2 = agent("b", status: "blocked", cwd: "/Users/dev"); blank2.hostId = "mac"
        var asking = agent("c", status: "blocked", cwd: "/Users/dev"); asking.hostId = "mac"
        var otherFolder = agent("d", status: "blocked", cwd: "/Users/dev/Projects/api"); otherFolder.hostId = "mac"
        var otherHost = agent("e", status: "blocked", cwd: "/Users/dev"); otherHost.hostId = "pc"
        var named = agent("f", status: "blocked", cwd: "/Users/dev"); named.hostId = "mac"; named.tabLabel = "Redesign"
        var blank3 = agent("g", status: "blocked", cwd: "/Users/dev"); blank3.hostId = "mac"

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
        var one = agent("a", status: "blocked", cwd: "/Users/dev/p"); one.hostId = "mac"
        var two = agent("b", status: "blocked", cwd: "/Users/dev/p"); two.hostId = "mac"
        let groups = HomeGrouping.waitingGroups([one, two]) { _ in "Continue? [y/N]" }
        #expect(groups.count == 1)
        #expect(groups[0].askingLine == "Continue? [y/N]")
    }
}
