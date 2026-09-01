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

    private let computer = (id: "https://mac.example", name: "MacBook")

    @Test
    func groupsAgentsByFolderAndKeepsNeedsYouAboveEverything() {
        let layout = HomeGrouping.layout(
            agents: [
                agent("a", status: "working", cwd: "/Users/dev/Projects/api"),
                agent("b", status: "blocked", cwd: "/Users/dev/Projects/web"),
                agent("c", status: "done", cwd: "/Users/dev/Projects/api"),
                agent("d", status: "idle", cwd: "/Users/dev/Projects/web"),
            ],
            computer: computer
        )

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
        let layout = HomeGrouping.layout(
            agents: [agent("b", status: "blocked", cwd: "/p/web")],
            computer: computer
        )

        // The folder keeps its header (it counts the waiting agent); the
        // agent itself is rendered only in the flat needs-you list.
        #expect(layout.computers.count == 1)
        #expect(layout.computers[0].projects.map(\.needsYou.count) == [1])
        #expect(!layout.isEmpty)
        #expect(HomeGrouping.layout(agents: [], computer: computer).isEmpty)
    }

    @Test
    func computerNamePrefersThePairedNameThenTheAddress() {
        #expect(HomeGrouping.computerName(pairedName: "Parvez's MacBook Air", hostText: "https://x.ts.net") == "Parvez's MacBook Air")
        #expect(HomeGrouping.computerName(pairedName: "  ", hostText: "https://parvezs-macbook-air.tail.ts.net") == "parvezs-macbook-air")
        #expect(HomeGrouping.computerName(pairedName: nil, hostText: "https://192.168.1.5:8787") == "192.168.1.5")
        #expect(HomeGrouping.computerName(pairedName: nil, hostText: "my-mac.tailnet.ts.net") == "my-mac")
        #expect(HomeGrouping.computerName(pairedName: nil, hostText: "") == "Paired computer")
    }
}
