import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import test, { type TestContext } from "node:test";
import { HerdrService } from "./herdr.js";

test("maps live herdr agents with provenance", async (context) => {
  const socketPath = temporarySocketPath(context);
  await startFakeHerdr(context, socketPath, {
    protocol: 17,
    agents: [
      {
        agent: "claude",
        agent_status: "blocked",
        cwd: "/Users/dev/project",
        focused: true,
        pane_id: "wB:p1",
        revision: 3,
        tab_id: "wB:t1",
        terminal_title: "✳ Claude Code",
        terminal_title_stripped: "Claude Code",
        workspace_id: "wB",
      },
      {
        agent: "codex",
        agent_status: "definitely-new-status",
        pane_id: "wB:p2",
        tab_id: "wB:t2",
        workspace_id: "wB",
      },
    ],
  });

  const result = await new HerdrService({ socketPath }).listAgents();

  assert.equal(result.available, true);
  assert.equal(result.protocol, 17);
  assert.deepEqual(
    result.agents.map(({ id, agent, status, title, focused, authority }) => ({
      id,
      agent,
      status,
      title,
      focused,
      authority,
    })),
    [
      {
        id: "wB:p1",
        agent: "claude",
        status: "blocked",
        title: "Claude Code",
        focused: true,
        authority: "herdr",
      },
      {
        id: "wB:p2",
        agent: "codex",
        status: "unknown",
        title: "",
        focused: false,
        authority: "herdr",
      },
    ],
  );
});

test("composes the workspace → tab → agent tree", async (context) => {
  const socketPath = temporarySocketPath(context);
  await startFakeHerdr(context, socketPath, {
    protocol: 17,
    agents: [
      {
        agent: "claude",
        agent_status: "working",
        pane_id: "wB:p1",
        tab_id: "wB:t1",
        workspace_id: "wB",
      },
    ],
    workspaces: [
      { workspace_id: "wB", number: 1, label: "~", focused: true },
      { workspace_id: "wC", number: 2, label: "side", focused: false },
    ],
    tabs: [
      { tab_id: "wB:t1", workspace_id: "wB", label: "tavi", focused: true },
      { tab_id: "wB:t2", workspace_id: "wB", label: "shell", focused: false },
      { tab_id: "wC:t1", workspace_id: "wC", label: "notes", focused: false },
    ],
  });

  const result = await new HerdrService({ socketPath }).listTree();

  assert.equal(result.available, true);
  assert.equal(result.available && result.workspaces.length, 2);
  if (!result.available) return;
  const [first, second] = result.workspaces;
  assert.deepEqual(
    { workspaceId: first?.workspaceId, label: first?.label, focused: first?.focused },
    { workspaceId: "wB", label: "~", focused: true },
  );
  assert.deepEqual(
    first?.tabs.map((tab) => ({ tabId: tab.tabId, label: tab.label, agents: tab.agents.length })),
    [
      { tabId: "wB:t1", label: "tavi", agents: 1 },
      { tabId: "wB:t2", label: "shell", agents: 0 },
    ],
  );
  assert.equal(first?.tabs[0]?.agents[0]?.id, "wB:p1");
  assert.deepEqual(
    second?.tabs.map((tab) => tab.tabId),
    ["wC:t1"],
  );
});

// #44: the size the Mac displays is the pane's rect in herdr's viewer
// layout, which is what the phone hands back on detach.
test("pane size comes from the viewer layout rect", async (context) => {
  const socketPath = temporarySocketPath(context);
  await startFakeHerdr(context, socketPath, {
    protocol: 17,
    agents: [],
    snapshot: {
      layouts: [
        {
          tab_id: "wB:t1",
          panes: [
            { pane_id: "wB:p1", rect: { x: 26, y: 1, width: 174, height: 49 } },
            { pane_id: "wB:p2", rect: { x: 0, y: 0, width: 0, height: 0 } },
          ],
        },
      ],
    },
  });
  const herdr = new HerdrService({ socketPath });

  assert.deepEqual(await herdr.paneSize("wB:p1"), { cols: 174, rows: 49 });
  // A zero rect is not a size worth handing back; an unknown pane has none.
  assert.equal(await herdr.paneSize("wB:p2"), undefined);
  assert.equal(await herdr.paneSize("wB:p9"), undefined);
});

test("pane size is unknown when herdr is down", async (context) => {
  const socketPath = temporarySocketPath(context);
  assert.equal(await new HerdrService({ socketPath }).paneSize("wB:p1"), undefined);
});

test("tree degrades to unavailable when herdr is down", async (context) => {
  const socketPath = temporarySocketPath(context);

  const result = await new HerdrService({ socketPath }).listTree();

  assert.equal(result.available, false);
  assert.equal(!result.available && result.reason, "The Herdr server is not running.");
});

test("prompt nudges an unsubmitted composer with Enter", async (context) => {
  const socketPath = temporarySocketPath(context);
  const methodCalls: string[] = [];
  await startFakeHerdr(context, socketPath, {
    protocol: 17,
    agents: [{ agent: "claude", agent_status: "idle", pane_id: "wB:p1", tab_id: "wB:t1", workspace_id: "wB" }],
    // The pane still shows the prompt sitting in the composer (wrapped).
    readText: "run exactly this\ncommand: touch /tmp/probe",
    methodCalls,
  });

  const service = new HerdrService({ socketPath, promptSettleMilliseconds: 10 });
  const result = await service.promptAgent("wB:p1", "run exactly this command: touch /tmp/probe");

  assert.equal(result.submitted, true);
  assert.ok(methodCalls.includes("agent.send_keys"), "expected an Enter nudge");
});

test("prompt never nudges once the agent has reacted", async (context) => {
  const socketPath = temporarySocketPath(context);
  const methodCalls: string[] = [];
  await startFakeHerdr(context, socketPath, {
    protocol: 17,
    // Working means the prompt took — or a dialog may be up. Hands off.
    agents: [{ agent: "claude", agent_status: "working", pane_id: "wB:p1", tab_id: "wB:t1", workspace_id: "wB" }],
    readText: "run exactly this command: touch /tmp/probe",
    methodCalls,
  });

  const service = new HerdrService({ socketPath, promptSettleMilliseconds: 10 });
  const result = await service.promptAgent("wB:p1", "run exactly this command: touch /tmp/probe");

  assert.equal(result.submitted, true);
  assert.equal(methodCalls.includes("agent.send_keys"), false);
});

test("prompt falls back to typing when herdr insists the launch is pending", async (context) => {
  const socketPath = temporarySocketPath(context);
  const sentKeys: string[][] = [];
  await startFakeHerdr(context, socketPath, {
    protocol: 17,
    agents: [{ agent: "claude", agent_status: "idle", pane_id: "wB:p1", tab_id: "wB:t1", workspace_id: "wB" }],
    promptError: "agent wB:p1 is not an active named agent",
    sentKeys,
  });

  const service = new HerdrService({ socketPath, promptSettleMilliseconds: 10 });
  const result = await service.promptAgent("wB:p1", "hi there");

  assert.equal(result.submitted, true);
  assert.equal(sentKeys.length, 1);
  assert.deepEqual(sentKeys[0], ["h", "i", "Space", "t", "h", "e", "r", "e", "Enter"]);
});

test("typing fallback refuses non-idle panes", async (context) => {
  const socketPath = temporarySocketPath(context);
  const sentKeys: string[][] = [];
  await startFakeHerdr(context, socketPath, {
    protocol: 17,
    // Blocked pane: a blind keystroke could answer the dialog. Hands off.
    agents: [{ agent: "claude", agent_status: "blocked", pane_id: "wB:p1", tab_id: "wB:t1", workspace_id: "wB" }],
    promptError: "agent wB:p1 is not an active named agent",
    sentKeys,
  });

  const service = new HerdrService({ socketPath, promptSettleMilliseconds: 10 });
  const result = await service.promptAgent("wB:p1", "hi there");

  assert.equal(result.submitted, false);
  assert.equal(sentKeys.length, 0);
});

test("approves a live dialog by sending Enter after re-reading the pane", async (context) => {
  const socketPath = temporarySocketPath(context);
  const sentKeys: string[][] = [];
  await startFakeHerdr(context, socketPath, {
    protocol: 17,
    agents: [{ agent: "claude", agent_status: "blocked", pane_id: "wB:p1", tab_id: "wB:t1", workspace_id: "wB" }],
    readText: " Do you want to proceed?\n ❯ 1. Yes\n   2. No, exit\n\n Enter to confirm · Esc to cancel",
    sentKeys,
  });

  const result = await new HerdrService({ socketPath }).decideAgent("wB:p1", "approve");

  assert.deepEqual(result, { decided: true, sent: "Enter" });
  assert.deepEqual(sentKeys, [["Enter"]]);
});

test("picks a specific numbered option by sending its digit", async (context) => {
  const socketPath = temporarySocketPath(context);
  const sentKeys: string[][] = [];
  await startFakeHerdr(context, socketPath, {
    protocol: 17,
    agents: [{ agent: "claude", agent_status: "blocked", pane_id: "wB:p1", tab_id: "wB:t1", workspace_id: "wB" }],
    readText: " Proceed?\n ❯ 1. Yes\n   2. Yes, always allow\n   3. No\n\n Esc to cancel",
    sentKeys,
  });

  const result = await new HerdrService({ socketPath }).decideAgent("wB:p1", { option: 2 });

  assert.deepEqual(result, { decided: true, sent: "2" });
  assert.deepEqual(sentKeys, [["2"]]);
});

test("refuses an option the dialog on screen does not offer", async (context) => {
  const socketPath = temporarySocketPath(context);
  const sentKeys: string[][] = [];
  await startFakeHerdr(context, socketPath, {
    protocol: 17,
    agents: [{ agent: "claude", agent_status: "blocked", pane_id: "wB:p1", tab_id: "wB:t1", workspace_id: "wB" }],
    readText: " ❯ 1. Yes\n   2. No\n\n Esc to cancel",
    sentKeys,
  });

  const result = await new HerdrService({ socketPath }).decideAgent("wB:p1", { option: 5 });

  assert.equal(result.decided, false);
  assert.equal(result.decided === false && result.stale, true);
  assert.equal(sentKeys.length, 0);
});

test("denies a live dialog with Escape", async (context) => {
  const socketPath = temporarySocketPath(context);
  const sentKeys: string[][] = [];
  await startFakeHerdr(context, socketPath, {
    protocol: 17,
    agents: [{ agent: "claude", agent_status: "blocked", pane_id: "wB:p1", tab_id: "wB:t1", workspace_id: "wB" }],
    readText: " ❯ 1. Yes\n   2. No\n\n Enter to confirm · Esc to cancel",
    sentKeys,
  });

  const result = await new HerdrService({ socketPath }).decideAgent("wB:p1", "deny");

  assert.deepEqual(result, { decided: true, sent: "Escape" });
  assert.deepEqual(sentKeys, [["Escape"]]);
});

test("refuses to decide and fires no key when the dialog is already gone", async (context) => {
  const socketPath = temporarySocketPath(context);
  const sentKeys: string[][] = [];
  await startFakeHerdr(context, socketPath, {
    protocol: 17,
    agents: [{ agent: "claude", agent_status: "idle", pane_id: "wB:p1", tab_id: "wB:t1", workspace_id: "wB" }],
    // The pane moved on — no dialog footer to be found.
    readText: "❯ ls -la\n  ctx 0/200k",
    sentKeys,
  });

  const result = await new HerdrService({ socketPath }).decideAgent("wB:p1", "approve");

  assert.equal(result.decided, false);
  assert.equal(result.decided === false && result.stale, true);
  assert.equal(sentKeys.length, 0);
});

test("reads and parses a live dialog", async (context) => {
  const socketPath = temporarySocketPath(context);
  await startFakeHerdr(context, socketPath, {
    protocol: 17,
    agents: [{ agent: "claude", agent_status: "blocked", pane_id: "wB:p1", tab_id: "wB:t1", workspace_id: "wB" }],
    readText: " Bash: rm file\n ❯ 1. Yes\n   2. No\n\n Enter to confirm · Esc to cancel",
  });

  const result = await new HerdrService({ socketPath }).readDialog("wB:p1");

  assert.equal("available" in result, false);
  assert.equal("present" in result && result.present, true);
  if (!("present" in result) || !result.present) return;
  assert.equal(result.dialog.options.length, 2);
  assert.equal(result.dialog.options[0]?.selected, true);
});

test("reports unavailable when the herdr server is not running", async (context) => {
  const socketPath = temporarySocketPath(context);

  const result = await new HerdrService({ socketPath }).listAgents();

  assert.equal(result.available, false);
  assert.equal(result.agents.length, 0);
  assert.equal(result.reason, "The Herdr server is not running.");
});

test("fails closed on an unsupported herdr protocol", async (context) => {
  const socketPath = temporarySocketPath(context);
  await startFakeHerdr(context, socketPath, { protocol: 16, agents: [] });

  const result = await new HerdrService({ socketPath }).listAgents();

  assert.equal(result.available, false);
  assert.equal(result.agents.length, 0);
  assert.match(result.reason ?? "", /too old for Tavi \(protocol 16/);
});

test("a newer herdr that keeps the agent shape just works; one that breaks it asks for a Tavi update", async (context) => {
  const newer = temporarySocketPath(context);
  await startFakeHerdr(context, newer, {
    protocol: 21,
    agents: [{ agent: "claude", agent_status: "idle", cwd: "/", pane_id: "w1:p1", tab_id: "w1:t1", workspace_id: "w1", revision: 1, brand_new_field: true }],
  });
  const fine = await new HerdrService({ socketPath: newer }).listAgents();
  assert.equal(fine.available, true);
  assert.equal(fine.protocol, 21);
  assert.equal(fine.agents[0]?.id, "w1:p1");

  const broken = temporarySocketPath(context);
  await startFakeHerdr(context, broken, { protocol: 22, agents: [{ agent: "claude", status: "idle", pane: "w1:p1" }] });
  const result = await new HerdrService({ socketPath: broken }).listAgents();
  assert.equal(result.available, false);
  assert.match(result.reason ?? "", /does not understand.*npx tavi-host@latest pair/);
});

test("reports unavailable when herdr stops responding", async (context) => {
  const socketPath = temporarySocketPath(context);
  const server = createServer(() => {
    // Accept the connection and never answer.
  });
  await listen(context, server, socketPath);

  const result = await new HerdrService({
    socketPath,
    requestTimeoutMilliseconds: 100,
  }).listAgents();

  assert.equal(result.available, false);
  assert.equal(result.reason, "Herdr did not respond in time.");
});

test("joins tab labels onto agents and renames tabs", async (context) => {
  const socketPath = temporarySocketPath(context);
  const methodCalls: string[] = [];
  await startFakeHerdr(context, socketPath, {
    protocol: 17,
    agents: [
      { agent: "claude", agent_status: "idle", cwd: "/w", pane_id: "wB:p1", tab_id: "wB:t1", workspace_id: "wB" },
      { agent: "shell", agent_status: "idle", cwd: "/w", pane_id: "wB:p2", tab_id: "wB:t9", workspace_id: "wB" },
    ],
    tabs: [{ tab_id: "wB:t1", workspace_id: "wB", label: "fix auth bug", focused: false }],
    methodCalls,
  });
  const service = new HerdrService({ socketPath });

  const result = await service.listAgents();
  assert.equal(result.available, true);
  assert.equal(result.agents[0]?.tabLabel, "fix auth bug");
  // A tab herdr does not list leaves its agent without a label rather
  // than inventing one.
  assert.equal(result.agents[1]?.tabLabel, undefined);
  assert.ok(methodCalls.includes("tab.list"));

  const renamed = await service.renameTab("wB:t1", "ship the fix");
  assert.deepEqual(renamed, { renamed: true, label: "ship the fix" });
});

function temporarySocketPath(context: TestContext): string {
  const directory = mkdtempSync(path.join(tmpdir(), "tavi-herdr-test-"));
  context.after(() => rmSync(directory, { recursive: true, force: true }));
  return path.join(directory, "herdr.sock");
}

async function startFakeHerdr(
  context: TestContext,
  socketPath: string,
  behavior: {
    protocol: number;
    agents: unknown[];
    workspaces?: unknown[];
    tabs?: unknown[];
    readText?: string;
    snapshot?: unknown;
    promptError?: string;
    methodCalls?: string[];
    sentKeys?: string[][];
  },
): Promise<void> {
  const server = createServer((socket) => {
    let buffered = "";
    socket.on("data", (chunk) => {
      buffered += chunk.toString("utf8");
      const lineEnd = buffered.indexOf("\n");
      if (lineEnd === -1) return;
      const request = JSON.parse(buffered.slice(0, lineEnd)) as {
        id: string;
        method: string;
        params?: { keys?: string[]; tab_id?: string; label?: string };
      };
      buffered = buffered.slice(lineEnd + 1);
      behavior.methodCalls?.push(request.method);
      if (request.method === "agent.send_keys" && request.params?.keys) {
        behavior.sentKeys?.push(request.params.keys);
      }
      if (request.method === "agent.prompt" && behavior.promptError) {
        socket.write(
          `${JSON.stringify({ id: request.id, error: { code: "invalid_request", message: behavior.promptError } })}\n`,
        );
        return;
      }
      const result =
        request.method === "ping"
          ? { type: "pong", version: "0.7.5", protocol: behavior.protocol }
          : request.method === "workspace.list"
            ? { type: "workspace_list", workspaces: behavior.workspaces ?? [] }
            : request.method === "tab.list"
              ? { type: "tab_list", tabs: behavior.tabs ?? [] }
              : request.method === "agent.read"
                ? { type: "pane_read", read: { text: behavior.readText ?? "" } }
                : request.method === "session.snapshot"
                  ? { type: "session_snapshot", snapshot: behavior.snapshot ?? {} }
                : request.method === "agent.prompt" || request.method === "agent.send_keys"
                  ? { type: "ok" }
                  : request.method === "tab.rename"
                    ? {
                        type: "tab_info",
                        tab: { tab_id: request.params?.tab_id ?? "", label: request.params?.label ?? "" },
                      }
                    : { type: "agent_list", agents: behavior.agents };
      socket.write(`${JSON.stringify({ id: request.id, result })}\n`);
    });
  });
  await listen(context, server, socketPath);
}

function listen(context: TestContext, server: Server, socketPath: string): Promise<void> {
  context.after(() => {
    server.close();
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
}

test("attach always takes over a stale client (owner, robin-PC 2026-09-02)", () => {
  const herdr = new HerdrService({ socketPath: "/tmp/none.sock" });
  assert.deepEqual(herdr.attachCommand("wB:p1"), { bin: "herdr", args: ["agent", "attach", "wB:p1", "--takeover"] });
});
