import Foundation
@testable import Tavi
import Testing

// The eleven routes the directory itself calls (#96): each one asks the
// address it always asked, reads a good answer into its own value, and
// turns a refusal into words a person can act on — including the #81
// "update your host" sentence, now reachable from every one of them.
@MainActor
struct HostRoutesTests {
    private static let tooOld = "This computer's Tavi host is too old to do that. Update it with `npx tavi-host update`."
    // What a host that has never heard of the route answers.
    private static let oldHost = StubHost.Answer.json(404, #"{"error":"Not found."}"#)

    private static func routes(_ answers: StubHost.Answer...) throws -> HostRoutes {
        try Fixtures.hostRoutes(StubHost(answers))
    }

    private static func asking(_ answers: StubHost.Answer...) throws -> (HostRoutes, StubHost) {
        let host = StubHost(answers)
        return (try Fixtures.hostRoutes(host), host)
    }

    // MARK: - GET /api/projects

    @Test func projectsBecomeTheCatalogThePickerOffers() async throws {
        let (routes, host) = try Self.asking(.json(200, #"""
        {"recent":[{"path":"/repo","name":"repo","active":true,"withinRoots":true}],
         "workspaces":[{"name":"repo","path":"/repo","git":true}],
         "roots":["/Users/dev/Projects"],
         "agents":[{"kind":"claude","label":"Claude Code","installed":true}]}
        """#))
        guard case let .catalog(catalog) = await routes.fetchProjects() else {
            Issue.record("expected a catalog")
            return
        }
        #expect(await host.calls == ["GET /api/projects"])
        #expect(catalog.recent.map(\.path) == ["/repo"])
    }

    @Test func projectsFromAnOldHostSayToUpdateIt() async throws {
        let routes = try Self.routes(Self.oldHost)
        #expect(await routes.fetchProjects() == .failure(Self.tooOld))
    }

    // MARK: - GET /api/repos

    @Test func reposBecomeTheWorktreesBehindTheCards() async throws {
        let (routes, host) = try Self.asking(.json(200, #"""
        {"repos":[{"root":"/repo","name":"repo","defaultBranch":"main","worktrees":[
          {"path":"/repo","branch":"main","head":"a1b2c3d","isMain":true,"dirty":2,
           "ahead":1,"behind":0,"locked":false,"prunable":false}]}]}
        """#))
        guard case let .repos(repos) = await routes.fetchRepos() else {
            Issue.record("expected repos")
            return
        }
        #expect(await host.calls == ["GET /api/repos"])
        #expect(repos.first?.worktrees.first?.dirty == 2)
    }

    @Test func aFreshReposPollAsksTheHostToSkipItsCache() async throws {
        let (routes, host) = try Self.asking(.json(200, #"{"repos":[]}"#))
        _ = await routes.fetchRepos(fresh: true)
        let request = await host.lastRequest
        #expect(request?.url?.query == "fresh=1")
    }

    @Test func reposFromAnOldHostSayToUpdateIt() async throws {
        let routes = try Self.routes(Self.oldHost)
        #expect(await routes.fetchRepos() == .failure(Self.tooOld))
    }

    // MARK: - POST /api/worktrees

    @Test func aCreatedWorktreeComesBackWithWhereItLanded() async throws {
        let (routes, host) = try Self.asking(.json(201, #"""
        {"worktree":{"path":"/repo-fix","branch":"fix","base":"main","repoRoot":"/repo","copiedSetupFiles":2}}
        """#))
        let outcome = await routes.createWorktree(repo: "/repo", branch: "fix", base: "main")
        guard case let .created(worktree) = outcome else {
            Issue.record("expected a worktree")
            return
        }
        #expect(await host.calls == ["POST /api/worktrees"])
        #expect(worktree.path == "/repo-fix")
    }

    // The host owns the roots rule, so a location it flags comes back as a
    // question to the person, never as a failure.
    @Test func aWorktreeOutsideTheRootsAsksBeforeItFails() async throws {
        let routes = try Self.routes(.json(400, #"{"error":"Outside your project folders.","outsideRoots":true}"#))
        let outcome = await routes.createWorktree(repo: "/tmp/x", branch: "fix", base: nil)
        #expect(outcome == .needsOutsideRootsConfirmation("Outside your project folders."))
    }

    @Test func aWorktreeRefusalSpeaksTheHostsOwnSentence() async throws {
        let routes = try Self.routes(.json(409, #"{"error":"That branch already has a worktree."}"#))
        let outcome = await routes.createWorktree(repo: "/repo", branch: "fix", base: nil)
        #expect(outcome == .failure("That branch already has a worktree."))
    }

    @Test func aWorktreeRouteAnOldHostLacksSaysToUpdateIt() async throws {
        let routes = try Self.routes(Self.oldHost)
        #expect(await routes.createWorktree(repo: "/repo", branch: "fix", base: nil) == .failure(Self.tooOld))
    }

    // MARK: - POST /api/herdr/tabs

    @Test func aCreatedTabComesBackWithThePaneToOpen() async throws {
        let (routes, host) = try Self.asking(.json(201, #"{"paneId":"pane-9","tabId":"tab-9"}"#))
        #expect(await routes.createTab(agent: "claude", cwd: "/repo") == .created(paneId: "pane-9", tabId: "tab-9"))
        #expect(await host.calls == ["POST /api/herdr/tabs"])
    }

    @Test func aTabOutsideTheRootsAsksBeforeItFails() async throws {
        let routes = try Self.routes(.json(400, #"{"error":"Outside.","outsideRoots":true}"#))
        #expect(await routes.createTab(agent: nil, cwd: "/tmp/x") == .needsOutsideRootsConfirmation)
    }

    @Test func aTabRefusalSpeaksTheHostsOwnSentence() async throws {
        let routes = try Self.routes(.json(503, #"{"error":"Herdr is not running."}"#))
        #expect(await routes.createTab(agent: nil, cwd: "/repo") == .failure("Herdr is not running."))
    }

    // MARK: - DELETE /api/devices/me

    @Test func unpairingSaysNothingWhenTheHostRevokedThisPhone() async throws {
        let (routes, host) = try Self.asking(.json(204, ""))
        #expect(await routes.unpairSelf() == nil)
        #expect(await host.calls == ["DELETE /api/devices/me"])
    }

    // A credential the host already forgot leaves this phone unpaired too.
    @Test func unpairingIsDoneWhenTheCredentialIsAlreadyDead() async throws {
        let routes = try Self.routes(.json(401, #"{"error":"Unauthorized."}"#))
        #expect(await routes.unpairSelf() == nil)
    }

    @Test func aComputerThatIsOffIsNamedAsTheReasonUnpairingFailed() async throws {
        let routes = try Self.routes(.silence)
        let message = await routes.unpairSelf()
        #expect(message?.hasPrefix("Could not reach the computer: ") == true)
    }

    @Test func anUnpairRefusalSpeaksTheHostsOwnSentence() async throws {
        let routes = try Self.routes(.json(500, #"{"error":"Could not write the device list."}"#))
        #expect(await routes.unpairSelf() == "Could not write the device list.")
    }

    // MARK: - GET /api/agents/{pane}/dialog

    @Test func aRenderedDialogComesBackWithItsChoices() async throws {
        let (routes, host) = try Self.asking(.json(200, #"""
        {"present":true,"dialog":{"prompt":"Run rm -rf?","options":[{"index":1,"label":"Yes","selected":true}]}}
        """#))
        guard case let .dialog(dialog) = await routes.fetchDialog(paneId: "pane-1") else {
            Issue.record("expected a dialog")
            return
        }
        #expect(await host.calls == ["GET /api/agents/pane-1/dialog"])
        #expect(dialog.options.map(\.label) == ["Yes"])
    }

    // The wait may have resolved between the card and the sheet; that is
    // "nothing to answer", not a failure.
    @Test func aDialogThatResolvedIsNoneRatherThanAFailure() async throws {
        let routes = try Self.routes(.json(200, #"{"present":false}"#))
        #expect(await routes.fetchDialog(paneId: "pane-1") == DialogFetch.none)
    }

    @Test func aDialogRefusalSpeaksTheHostsOwnSentence() async throws {
        let routes = try Self.routes(.json(404, #"{"error":"Herdr integration is not configured on this host."}"#))
        #expect(await routes.fetchDialog(paneId: "pane-1") == .failure("Herdr integration is not configured on this host."))
    }

    // MARK: - POST /api/agents/{pane}/decision

    @Test func aDeliveredDecisionIsOk() async throws {
        let (routes, host) = try Self.asking(.json(200, "{}"))
        #expect(await routes.decide(paneId: "pane-1", decision: .approve) == .ok)
        #expect(await host.calls == ["POST /api/agents/pane-1/decision"])
    }

    // 409 is the host saying the dialog was already gone, so the sheet can
    // say the wait resolved instead of implying the tap did something.
    @Test func aDecisionThatArrivedTooLateIsStale() async throws {
        let routes = try Self.routes(.json(409, #"{"error":"The dialog is gone."}"#))
        #expect(await routes.decide(paneId: "pane-1", decision: .deny) == .stale)
    }

    @Test func aNumberedChoiceIsSentAsItsIndex() async throws {
        let (routes, host) = try Self.asking(.json(200, "{}"))
        _ = await routes.decide(paneId: "pane-1", decision: .option(2))
        let request = await host.lastRequest
        let body = String(bytes: request?.httpBody ?? Data(), encoding: .utf8)
        #expect(body?.contains("\"option\":2") == true)
    }

    @Test func aDecisionRefusalSpeaksTheHostsOwnSentence() async throws {
        let routes = try Self.routes(.json(500, #"{"error":"The pane stopped responding."}"#))
        #expect(await routes.decide(paneId: "pane-1", decision: .approve) == .failure("The pane stopped responding."))
    }

    // MARK: - PATCH /api/herdr/tabs/{tab}

    @Test func aRenameThatLandedSaysNothing() async throws {
        let (routes, host) = try Self.asking(.json(200, "{}"))
        #expect(await routes.renameTab(tabId: "tab-1", label: "Fix login") == nil)
        #expect(await host.calls == ["PATCH /api/herdr/tabs/tab-1"])
    }

    @Test func aRenameRefusalSpeaksTheHostsOwnSentence() async throws {
        let routes = try Self.routes(.json(400, #"{"error":"That label is too long."}"#))
        #expect(await routes.renameTab(tabId: "tab-1", label: "…") == "That label is too long.")
    }

    // MARK: - POST /api/agents/{pane}/prompt

    @Test func aDeliveredPromptSaysNothing() async throws {
        let (routes, host) = try Self.asking(.json(202, ""))
        #expect(await routes.promptAgent(paneId: "pane-1", text: "hello") == nil)
        #expect(await host.calls == ["POST /api/agents/pane-1/prompt"])
    }

    @Test func aPromptRouteAnOldHostLacksSaysToUpdateIt() async throws {
        let routes = try Self.routes(Self.oldHost)
        #expect(await routes.promptAgent(paneId: "pane-1", text: "hello") == Self.tooOld)
    }

    // MARK: - GET /api/herdr/tree

    // Every target is host + pane (#50), so the tree stamps its computer on
    // every agent it hands the Jump-to sheet.
    @Test func theTreeStampsEveryAgentWithItsComputer() async throws {
        let host = StubHost(.json(200, #"""
        {"workspaces":[{"workspaceId":"ws-1","label":"Main","focused":true,"tabs":[
          {"tabId":"tab-1","label":"tavi","focused":true,"agents":[
            {"id":"pane-1","agent":"claude","status":"working","cwd":"/repo","title":"",
             "workspaceId":"ws-1","tabId":"tab-1","focused":true}]}]}]}
        """#))
        let routes = try Fixtures.hostRoutes(host, hostId: "studio")
        guard case let .tree(workspaces) = await routes.fetchTree() else {
            Issue.record("expected a tree")
            return
        }
        #expect(await host.calls == ["GET /api/herdr/tree"])
        #expect(workspaces.first?.tabs.first?.agents.first?.hostId == "studio")
    }

    @Test func aTreeRefusalSpeaksTheHostsOwnSentence() async throws {
        let routes = try Self.routes(.json(503, #"{"error":"Herdr is not running."}"#))
        #expect(await routes.fetchTree() == .failure("Herdr is not running."))
    }

    // MARK: - GET /api/agents/{pane}/preview

    @Test func anExcerptComesBackAsTheCardsSubtitle() async throws {
        let (routes, host) = try Self.asking(.json(200, #"{"preview":"Running tests…"}"#))
        #expect(await routes.preview(paneId: "pane-1") == "Running tests…")
        #expect(await host.calls == ["GET /api/agents/pane-1/preview"])
    }

    // A card without an excerpt is an ordinary card, so every failure here
    // is silence rather than a message nobody asked for.
    @Test func anExcerptTheHostRefusesIsSilence() async throws {
        let routes = try Self.routes(.json(500, #"{"error":"No pane."}"#))
        #expect(await routes.preview(paneId: "pane-1") == nil)
    }

    // MARK: - Not configured

    @Test func nothingIsAskedOfAComputerThatIsNotPairedYet() async {
        let host = StubHost()
        let routes = HostRoutes(transport: host.transport)
        #expect(await routes.fetchProjects() == .failure("Connect a host first."))
        #expect(await host.calls.isEmpty)
    }
}
