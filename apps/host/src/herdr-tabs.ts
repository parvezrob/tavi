import { randomBytes } from "node:crypto";
import { SHELL_KIND } from "./agent-kinds.js";
import { asArray, asRecord, asString, describeConnectionFailure, type HerdrRpc, sleep } from "./herdr-rpc.js";
import type {
  HerdrTabCloseResult,
  HerdrTabRenameResult,
  HerdrTabRequest,
  HerdrTabResult,
  HerdrTreeResult,
  HerdrTreeTab,
} from "./herdr-types.js";
import type { HerdrAgentInfo, HerdrAgentsResult } from "./types.js";

// herdr's tabs and the workspace → tab → agents tree (#55, #67, the Jump-to
// sheet). Split out of herdr.ts in #98: these speak about tabs, where the
// rest of the service speaks about agent panes. Each takes the connection it
// should use, so `HerdrService` stays the one thing that owns one.

// Verified live on the socket: tab.rename answers { type: "tab_info",
// tab: { ..., label } } with the applied label.
export async function renameTab(rpc: HerdrRpc, tabId: string, label: string): Promise<HerdrTabRenameResult> {
  try {
    const result = asRecord(await rpc.request("tab.rename", { tab_id: tabId, label }));
    const applied = asString(asRecord(result.tab).label);
    return { renamed: true, label: applied || label };
  } catch (error) {
    return { renamed: false, reason: describeConnectionFailure(error) };
  }
}

// Workspace → tab → agents hierarchy for the Jump-to sheet. Composed from
// workspace.list + tab.list (verified shapes: {workspaces: [{workspace_id,
// label, focused, ...}]} and {tabs: [{tab_id, workspace_id, label, focused,
// ...}]}) plus the protocol-gated agent list, so every displayed agent
// carries the same identity the events feed uses.
export async function listTree(rpc: HerdrRpc, agents: HerdrAgentsResult): Promise<HerdrTreeResult> {
  if (!agents.available) {
    return { available: false, reason: agents.reason ?? "Herdr is unavailable." };
  }

  try {
    const [workspacesRaw, tabsRaw] = await Promise.all([
      rpc.request("workspace.list", {}),
      rpc.request("tab.list", {}),
    ]);
    const workspaces = asArray(asRecord(workspacesRaw).workspaces).map(asRecord);
    const tabs = asArray(asRecord(tabsRaw).tabs).map(asRecord);

    const agentsByTab = new Map<string, HerdrAgentInfo[]>();
    for (const agent of agents.agents) {
      const existing = agentsByTab.get(agent.tabId) ?? [];
      existing.push(agent);
      agentsByTab.set(agent.tabId, existing);
    }

    const tabsByWorkspace = new Map<string, HerdrTreeTab[]>();
    for (const tab of tabs) {
      const workspaceId = asString(tab.workspace_id);
      const tabId = asString(tab.tab_id);
      if (!workspaceId || !tabId) continue;
      const existing = tabsByWorkspace.get(workspaceId) ?? [];
      existing.push({
        tabId,
        label: asString(tab.label),
        focused: tab.focused === true,
        agents: agentsByTab.get(tabId) ?? [],
      });
      tabsByWorkspace.set(workspaceId, existing);
    }

    return {
      available: true,
      workspaces: workspaces
        .filter((workspace) => asString(workspace.workspace_id) !== "")
        .map((workspace) => ({
          workspaceId: asString(workspace.workspace_id),
          label: asString(workspace.label),
          focused: workspace.focused === true,
          tabs: tabsByWorkspace.get(asString(workspace.workspace_id)) ?? [],
        })),
    };
  } catch (error) {
    return { available: false, reason: describeConnectionFailure(error) };
  }
}

// Verified live: tab.create answers { type: "tab_created", tab, root_pane },
// and agent.start launches the agent binary in that pane.
export async function createTab(
  rpc: HerdrRpc,
  request: HerdrTabRequest,
  reportShellPane: (paneId: string) => Promise<void>,
): Promise<HerdrTabResult> {
  try {
    const created = asRecord(
      await rpc.request("tab.create", {
        cwd: request.cwd ?? null,
        label: request.label ?? null,
        focus: false,
      }),
    );
    const tabId = asString(asRecord(created.tab).tab_id);
    const paneId = asString(asRecord(created.root_pane).pane_id);
    if (!tabId || !paneId) {
      return { created: false, reason: "Herdr did not report the new tab." };
    }
    if (request.agent === SHELL_KIND) {
      // Nothing to launch — the pane already is a shell. Report it as an
      // agent so herdr lists it and lets the pty bridge attach. Herdr
      // keeps the reported label over its own detection for the pane's
      // life, so when an agent later starts inside, the events feed hands
      // the pane back (#66, releaseShellAuthority).
      try {
        await reportShellPane(paneId);
      } catch (reportError) {
        await rpc.request("tab.close", { tab_id: tabId }).catch(() => undefined);
        throw reportError;
      }
    } else if (request.agent) {
      try {
        // The fresh pane's shell needs a moment to boot; until then
        // agent.start answers "not an available shell". Retry briefly.
        await retry(10, 300, () =>
          rpc.request("agent.start", {
            // Herdr requires a globally unique agent name; the kind alone
            // collides as soon as a second claude/codex exists.
            name: `${request.agent}-${randomBytes(2).toString("hex")}`,
            kind: request.agent,
            pane_id: paneId,
          }),
        );
      } catch (startError) {
        // Don't leave an orphaned empty tab behind a failed launch.
        await rpc.request("tab.close", { tab_id: tabId }).catch(() => undefined);
        throw startError;
      }
    }
    return { created: true, paneId, tabId };
  } catch (error) {
    return { created: false, reason: describeConnectionFailure(error) };
  }
}

export async function closeTab(rpc: HerdrRpc, tabId: string): Promise<HerdrTabCloseResult> {
  try {
    await rpc.request("tab.close", { tab_id: tabId });
    return { closed: true };
  } catch (error) {
    return { closed: false, reason: describeConnectionFailure(error) };
  }
}

// A fresh pane's shell needs a moment to boot before `agent.start` will
// take: bounded attempts, a fixed delay, the last failure rethrown.
async function retry<T>(attempts: number, delayMilliseconds: number, run: () => Promise<T>): Promise<T> {
  let lastError: unknown;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      return await run();
    } catch (error) {
      lastError = error;
      await sleep(delayMilliseconds);
    }
  }
  throw lastError;
}
