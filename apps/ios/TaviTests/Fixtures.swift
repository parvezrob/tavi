import Foundation
@testable import Tavi
import Testing

// Defaults are the values the suites already built by hand, so no assertion changes meaning.
enum Fixtures {
    static func agentSummary(
        id: String = "pane-1",
        agent: String = "claude",
        status: String = "working",
        cwd: String = "/Users/dev/projects/tavi",
        title: String = "",
        workspaceId: String = "ws-1",
        tabId: String = "tab-1",
        tabLabel: String? = nil,
        focused: Bool = false
    ) -> AgentSummary {
        AgentSummary(
            id: id,
            agent: agent,
            status: status,
            cwd: cwd,
            title: title,
            workspaceId: workspaceId,
            tabId: tabId,
            tabLabel: tabLabel,
            focused: focused
        )
    }

    static func hostEndpoint(_ baseURL: String = "https://studio.tailnet.ts.net") throws -> HostEndpoint {
        try HostEndpoint(baseURL: #require(URL(string: baseURL)))
    }
}
