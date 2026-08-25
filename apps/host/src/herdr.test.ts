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
      { tab_id: "wB:t1", workspace_id: "wB", label: "mocha", focused: true },
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
      { tabId: "wB:t1", label: "mocha", agents: 1 },
      { tabId: "wB:t2", label: "shell", agents: 0 },
    ],
  );
  assert.equal(first?.tabs[0]?.agents[0]?.id, "wB:p1");
  assert.deepEqual(
    second?.tabs.map((tab) => tab.tabId),
    ["wC:t1"],
  );
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
  assert.match(result.reason ?? "", /protocol 16 is not supported/);
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

function temporarySocketPath(context: TestContext): string {
  const directory = mkdtempSync(path.join(tmpdir(), "mocha-herdr-test-"));
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
        params?: { keys?: string[] };
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
                : request.method === "agent.prompt" || request.method === "agent.send_keys"
                  ? { type: "ok" }
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
