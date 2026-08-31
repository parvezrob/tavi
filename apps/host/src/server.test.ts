import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdirSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import test from "node:test";
import type { IPty } from "node-pty";
import WebSocket from "ws";
import { AttentionOverlay } from "./attention.js";
import type { HostConfig } from "./config.js";
import { TERMINAL_PROTOCOL } from "./protocol.js";
import type { HerdrAgentSource, HerdrTabRequest } from "./herdr.js";
import { ProjectHistory } from "./projects.js";
import { createMochaServer } from "./server.js";
import type { ServerTerminalMessage, SessionBackend } from "./types.js";

const config: HostConfig = {
  bindHost: "127.0.0.1",
  port: 0,
  token: "test-token-that-is-long-enough",
  shell: "/bin/sh",
  tmuxBin: "tmux",
  herdrSocket: "/tmp/mocha-test-herdr.sock",
  roots: [],
  stateDir: "/tmp",
  machineName: "test-host",
};

test("the host is API-only and does not serve a browser client", async () => {
  await withServer(async (origin) => {
    const response = await fetch(`${origin}/`);

    assert.equal(response.status, 404);
    assert.deepEqual(await response.json(), { error: "Not found." });
  });
});

test("the unauthenticated health endpoint remains available", async () => {
  await withServer(async (origin) => {
    const response = await fetch(`${origin}/api/health`);
    const body = (await response.json()) as { ok: boolean; version: string };

    assert.equal(response.status, 200);
    assert.equal(body.ok, true);
    assert.match(body.version, /^\d+\.\d+\.\d+$/);
  });
});

test("agents endpoint serves herdr state and degrades honestly without it", async () => {
  const herdr = {
    listAgents: async () => ({
      provider: "herdr" as const,
      available: true,
      protocol: 17,
      agents: [],
    }),
    findAgent: async () => ({ available: true as const }),
    attachCommand: (paneId: string) => ({ bin: "herdr", args: ["agent", "attach", paneId] }),
    readAgent: async () => ({ available: true as const, preview: "$ npm test\nall green" }),
    promptAgent: async () => ({ submitted: true as const }),
    createTab: async () => ({ created: true as const, paneId: "wB:p9", tabId: "wB:t9" }),
    readDialog: async () => ({ present: false as const }),
    decideAgent: async () => ({ decided: true as const, sent: "Enter" }),
    closeTab: async () => ({ closed: true as const }),
    listTree: async () => ({
      available: true as const,
      workspaces: [
        {
          workspaceId: "wB",
          label: "~",
          focused: true,
          tabs: [{ tabId: "wB:t1", label: "mocha", focused: true, agents: [] }],
        },
      ],
    }),
  };
  const server = await createMochaServer({ config, tmux: {} as SessionBackend, herdr });
  await listen(server);

  try {
    const address = server.address() as AddressInfo;
    const authorized = await fetch(`http://127.0.0.1:${address.port}/api/agents`, {
      headers: { Authorization: `Bearer ${config.token}` },
    });
    assert.equal(authorized.status, 200);
    assert.deepEqual(await authorized.json(), {
      provider: "herdr",
      available: true,
      protocol: 17,
      agents: [],
    });

    const unauthorized = await fetch(`http://127.0.0.1:${address.port}/api/agents`);
    assert.equal(unauthorized.status, 401);

    const tree = await fetch(`http://127.0.0.1:${address.port}/api/herdr/tree`, {
      headers: { Authorization: `Bearer ${config.token}` },
    });
    assert.equal(tree.status, 200);
    const treeBody = (await tree.json()) as { workspaces: Array<{ workspaceId: string }> };
    assert.equal(treeBody.workspaces[0]?.workspaceId, "wB");

    const closed = await fetch(`http://127.0.0.1:${address.port}/api/herdr/tabs/wB:t9`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${config.token}` },
    });
    assert.equal(closed.status, 200);
    assert.deepEqual(await closed.json(), { closed: true, tabId: "wB:t9" });
  } finally {
    await close(server);
  }

  const bareServer = await createMochaServer({ config, tmux: {} as SessionBackend });
  await listen(bareServer);
  try {
    const address = bareServer.address() as AddressInfo;
    const response = await fetch(`http://127.0.0.1:${address.port}/api/agents`, {
      headers: { Authorization: `Bearer ${config.token}` },
    });
    const body = (await response.json()) as { available: boolean; agents: unknown[] };
    assert.equal(body.available, false);
    assert.deepEqual(body.agents, []);
  } finally {
    await close(bareServer);
  }
});

test("claude hook events overlay blocked status with hook authority", async () => {
  const attention = new AttentionOverlay();
  const herdr = {
    listAgents: async () => ({
      provider: "herdr" as const,
      available: true,
      protocol: 17,
      agents: [
        {
          id: "wB:p1",
          agent: "claude",
          status: "idle" as const,
          cwd: "/work",
          title: "",
          workspaceId: "wB",
          tabId: "wB:t1",
          focused: false,
          revision: 1,
          authority: "herdr" as const,
          sessionRef: "sess-1",
        },
      ],
    }),
    listTree: async () => ({ available: true as const, workspaces: [] }),
    closeTab: async () => ({ closed: true as const }),
    findAgent: async () => ({ available: true as const }),
    attachCommand: (paneId: string) => ({ bin: "herdr", args: ["agent", "attach", paneId] }),
    readAgent: async () => ({ available: true as const, preview: "" }),
    promptAgent: async () => ({ submitted: true as const }),
    createTab: async () => ({ created: true as const, paneId: "wB:p9", tabId: "wB:t9" }),
    readDialog: async () => ({ present: false as const }),
    decideAgent: async () => ({ decided: true as const, sent: "Enter" }),
  };
  const server = await createMochaServer({ config, tmux: {} as SessionBackend, herdr, attention });
  await listen(server);

  try {
    const address = server.address() as AddressInfo;
    const base = `http://127.0.0.1:${address.port}`;
    const headers = { Authorization: `Bearer ${config.token}`, "Content-Type": "application/json" };

    const hooked = await fetch(`${base}/api/hooks/claude`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        hook_event_name: "Notification",
        session_id: "sess-1",
        cwd: "/work",
        message: "Claude needs your permission to use Bash",
      }),
    });
    assert.equal(hooked.status, 200);

    const blocked = (await (await fetch(`${base}/api/agents`, { headers })).json()) as {
      agents: Array<{ status: string; authority: string }>;
    };
    assert.equal(blocked.agents[0]?.status, "blocked");
    assert.equal(blocked.agents[0]?.authority, "claude-hook");

    await fetch(`${base}/api/hooks/claude`, {
      method: "POST",
      headers,
      body: JSON.stringify({ hook_event_name: "Stop", session_id: "sess-1" }),
    });
    const resolved = (await (await fetch(`${base}/api/agents`, { headers })).json()) as {
      agents: Array<{ status: string; authority: string }>;
    };
    assert.equal(resolved.agents[0]?.status, "idle");
    assert.equal(resolved.agents[0]?.authority, "herdr");

    const rejected = await fetch(`${base}/api/hooks/claude`, {
      method: "POST",
      headers,
      body: JSON.stringify({ nonsense: true }),
    });
    assert.equal(rejected.status, 400);
  } finally {
    await close(server);
  }
});

test("decision endpoint fires only when an authority flags the agent as waiting", async () => {
  const attention = new AttentionOverlay();
  const decisions: Array<{ paneId: string; decision: string }> = [];
  let status: "idle" | "blocked" = "idle";
  const makeAgent = () => ({
    id: "wB:p1",
    agent: "claude",
    status,
    cwd: "/work",
    title: "",
    workspaceId: "wB",
    tabId: "wB:t1",
    focused: false,
    revision: 1,
    authority: "herdr" as const,
    sessionRef: "sess-1",
  });
  const herdr = {
    listAgents: async () => ({ provider: "herdr" as const, available: true, protocol: 17, agents: [makeAgent()] }),
    listTree: async () => ({ available: true as const, workspaces: [] }),
    closeTab: async () => ({ closed: true as const }),
    findAgent: async () => ({ available: true as const, agent: makeAgent() }),
    attachCommand: (paneId: string) => ({ bin: "herdr", args: ["agent", "attach", paneId] }),
    readAgent: async () => ({ available: true as const, preview: "" }),
    readDialog: async () => ({ present: false as const }),
    decideAgent: async (paneId: string, decision: "approve" | "deny") => {
      decisions.push({ paneId, decision });
      return { decided: true as const, sent: decision === "approve" ? "Enter" : "Escape" };
    },
    promptAgent: async () => ({ submitted: true as const }),
    createTab: async () => ({ created: true as const, paneId: "wB:p9", tabId: "wB:t9" }),
  };
  const server = await createMochaServer({ config, tmux: {} as SessionBackend, herdr, attention });
  await listen(server);

  try {
    const address = server.address() as AddressInfo;
    const base = `http://127.0.0.1:${address.port}`;
    const headers = { Authorization: `Bearer ${config.token}`, "Content-Type": "application/json" };
    const decide = (decision: string) =>
      fetch(`${base}/api/agents/wB:p1/decision`, {
        method: "POST",
        headers,
        body: JSON.stringify({ decision }),
      });

    // Neither authority flags a wait: refuse, fire nothing.
    const idle = await decide("approve");
    assert.equal(idle.status, 409);
    assert.equal(decisions.length, 0);

    // herdr alone reporting blocked is enough for the outer layer (the inner
    // pane re-read is the real send-time safety).
    status = "blocked";
    const approved = await decide("approve");
    assert.equal(approved.status, 200);
    assert.deepEqual(decisions, [{ paneId: "wB:p1", decision: "approve" }]);

    // The hook overlay alone also qualifies, even with herdr idle.
    status = "idle";
    attention.report({ event: "PermissionRequest", sessionId: "sess-1" });
    const viaHook = await decide("deny");
    assert.equal(viaHook.status, 200);
    assert.deepEqual(decisions[1], { paneId: "wB:p1", decision: "deny" });

    const bad = await decide("maybe");
    assert.equal(bad.status, 400);
  } finally {
    await close(server);
  }
});

test("the project picker serves live agent folders, remembered choices, and roots", async () => {
  const stateDir = mkdtempSync(path.join(tmpdir(), "mocha-picker-state-"));
  const root = mkdtempSync(path.join(tmpdir(), "mocha-picker-root-"));
  // Both folders exist on disk: the picker never offers one that is gone.
  const api = path.join(root, "api");
  const web = path.join(root, "web");
  mkdirSync(api);
  mkdirSync(web);
  const projects = new ProjectHistory(stateDir);
  projects.remember(api);

  const herdr = stubHerdr({ cwd: web });
  const tmux = {
    listWorkspaces: async () => [{ name: "api", path: api, git: true }],
  } as unknown as SessionBackend;
  const server = await createMochaServer({
    config: { ...config, roots: [root] },
    tmux,
    herdr,
    projects,
  });
  await listen(server);

  try {
    const address = server.address() as AddressInfo;
    const response = await fetch(`http://127.0.0.1:${address.port}/api/projects`, {
      headers: { Authorization: `Bearer ${config.token}` },
    });
    assert.equal(response.status, 200);
    const body = (await response.json()) as {
      recent: Array<{ path: string; name: string; active: boolean; withinRoots: boolean }>;
      workspaces: Array<{ path: string }>;
      roots: string[];
    };

    // The folder an agent is living in leads; the remembered one follows.
    assert.deepEqual(body.recent.map((entry) => entry.path), [web, api]);
    assert.deepEqual(body.recent.map((entry) => entry.active), [true, false]);
    assert.equal(body.recent.every((entry) => entry.withinRoots), true);
    assert.deepEqual(body.workspaces, [{ name: "api", path: api, git: true }]);
    assert.deepEqual(body.roots, [root]);

    const unauthorized = await fetch(`http://127.0.0.1:${address.port}/api/projects`);
    assert.equal(unauthorized.status, 401);
  } finally {
    await close(server);
  }
});

test("creating an agent requires a real folder and confirmation outside the roots", async () => {
  const stateDir = mkdtempSync(path.join(tmpdir(), "mocha-create-state-"));
  const root = mkdtempSync(path.join(tmpdir(), "mocha-create-root-"));
  const project = mkdtempSync(path.join(root, "repo-"));
  const outside = mkdtempSync(path.join(tmpdir(), "mocha-create-outside-"));
  const projects = new ProjectHistory(stateDir);

  const created: Array<{ agent?: string | undefined; cwd?: string | undefined }> = [];
  const herdr = stubHerdr({
    onCreateTab: (request) => {
      created.push({ agent: request.agent, cwd: request.cwd });
    },
  });
  const server = await createMochaServer({
    config: { ...config, roots: [root] },
    tmux: {} as SessionBackend,
    herdr,
    projects,
  });
  await listen(server);

  try {
    const address = server.address() as AddressInfo;
    const headers = { Authorization: `Bearer ${config.token}`, "Content-Type": "application/json" };
    const create = (body: Record<string, unknown>) =>
      fetch(`http://127.0.0.1:${address.port}/api/herdr/tabs`, {
        method: "POST",
        headers,
        body: JSON.stringify(body),
      });

    // No folder at all: the old behaviour that born agents in ~ (#24).
    const homeless = await create({ agent: "claude" });
    assert.equal(homeless.status, 400);

    const missing = await create({ agent: "claude", cwd: path.join(root, "not-here") });
    assert.equal(missing.status, 400);

    const relative = await create({ agent: "claude", cwd: "repo" });
    assert.equal(relative.status, 400);

    // Outside the roots without the extra confirmation.
    const unconfirmed = await create({ agent: "claude", cwd: outside });
    assert.equal(unconfirmed.status, 400);
    assert.equal(((await unconfirmed.json()) as { outsideRoots?: boolean }).outsideRoots, true);
    assert.deepEqual(created, []);
    assert.deepEqual(projects.list(), []);

    // Inside a root: allowed with no confirmation, and remembered.
    const inside = await create({ agent: "claude", cwd: project });
    assert.equal(inside.status, 201);
    assert.deepEqual(created, [{ agent: "claude", cwd: project }]);
    assert.deepEqual(projects.list().map((entry) => entry.path), [project]);

    // Outside a root with the confirmation the phone sends after asking.
    const confirmed = await create({ agent: "codex", cwd: outside, allowOutsideRoots: true });
    assert.equal(confirmed.status, 201);
    assert.deepEqual(created.at(-1), { agent: "codex", cwd: outside });
    assert.deepEqual(projects.list().map((entry) => entry.path), [outside, project]);
  } finally {
    await close(server);
  }
});

test("terminal websocket authenticates and bridges typed protocol messages", async () => {
  const terminal = new FakeTerminal();
  const tmux = {
    getSession: async () => ({ id: "fixture" }),
    attachCommand: (id: string) => ({ bin: "tmux", args: ["-L", "mocha", "attach-session", "-t", id] }),
  } as unknown as SessionBackend;
  const server = await createMochaServer({
    config,
    tmux,
    spawnTerminal: () => terminal.pty,
  });
  await listen(server);

  const address = server.address() as AddressInfo;
  const websocket = new WebSocket(
    `ws://127.0.0.1:${address.port}/api/sessions/fixture/terminal`,
    [TERMINAL_PROTOCOL],
    { headers: { Authorization: `Bearer ${config.token}` } },
  );
  const messages = collectMessages(websocket);

  try {
    await once(websocket, "open");
    assert.equal((await messages.next()).value?.type, "ready");

    terminal.emitData("fixture output");
    assert.deepEqual(await messages.next(), {
      done: false,
      value: { type: "output", data: "fixture output" },
    });

    websocket.send(JSON.stringify({ type: "input", data: "echo safe\r" }));
    websocket.send(JSON.stringify({ type: "resize", cols: 999, rows: 1 }));
    websocket.send(JSON.stringify({ type: "ping", id: "heartbeat-1" }));

    assert.deepEqual(await messages.next(), {
      done: false,
      value: { type: "pong", id: "heartbeat-1" },
    });
    await waitUntil(() => terminal.writes.length === 1 && terminal.resizes.length === 1);
    assert.deepEqual(terminal.writes, ["echo safe\r"]);
    assert.deepEqual(terminal.resizes, [{ columns: 400, rows: 5 }]);

    websocket.send(JSON.stringify({ type: "unknown", data: "must-not-reach-pty" }));
    assert.deepEqual(await messages.next(), {
      done: false,
      value: { type: "error", message: "Invalid terminal message." },
    });
    assert.deepEqual(terminal.writes, ["echo safe\r"]);
  } finally {
    websocket.close();
    await once(websocket, "close");
    await waitUntil(() => terminal.killed);
    await close(server);
  }
});

test("terminal websocket rejects binary input without writing to the pty", async () => {
  const terminal = new FakeTerminal();
  const { server, websocket, messages } = await openTerminalSocket(terminal);

  try {
    const closed = once(websocket, "close");
    websocket.send(Buffer.from(JSON.stringify({ type: "input", data: "must-not-run\r" })));

    assert.deepEqual(await messages.next(), {
      done: false,
      value: { type: "error", message: "Binary terminal messages are unsupported." },
    });
    const [code] = await closed;
    assert.equal(code, 1003);
    assert.deepEqual(terminal.writes, []);
  } finally {
    await closeWebSocket(websocket);
    await waitUntil(() => terminal.killed);
    await close(server);
  }
});

test("terminal websocket rejects oversized client frames without writing to the pty", async () => {
  const terminal = new FakeTerminal();
  const { server, websocket, messages } = await openTerminalSocket(terminal);

  try {
    const closed = once(websocket, "close");
    websocket.send("x".repeat(64 * 1024 + 1));

    assert.deepEqual(await messages.next(), {
      done: false,
      value: { type: "error", message: "Terminal message is too large." },
    });
    const [code] = await closed;
    assert.equal(code, 1009);
    assert.deepEqual(terminal.writes, []);
  } finally {
    await closeWebSocket(websocket);
    await waitUntil(() => terminal.killed);
    await close(server);
  }
});

test("terminal websocket fail-closes when pending output exceeds its safety buffer", async () => {
  const terminal = new FakeTerminal();
  const { server, websocket, messages } = await openTerminalSocket(terminal);

  try {
    const closed = once(websocket, "close");
    terminal.emitData("x".repeat(256 * 1024 + 1));

    assert.deepEqual(await messages.next(), {
      done: false,
      value: {
        type: "error",
        message: "Terminal output exceeded the connection safety buffer.",
      },
    });
    const [code] = await closed;
    assert.equal(code, 1013);
    assert.equal(terminal.killed, true);
  } finally {
    await closeWebSocket(websocket);
    await close(server);
  }
});

test("terminal attach uses the backend attach command without pty flow control", async () => {
  const terminal = new FakeTerminal();
  let spawnedFile = "";
  let spawnedArgs: string[] = [];
  let spawnedOptions: Record<string, unknown> = {};
  const tmux = {
    getSession: async () => ({ id: "fixture" }),
    attachCommand: (id: string) => ({ bin: "tmux", args: ["-L", "mocha", "attach-session", "-t", id] }),
  } as unknown as SessionBackend;
  const server = await createMochaServer({
    config,
    tmux,
    spawnTerminal: (file, args, options) => {
      spawnedFile = file;
      spawnedArgs = [...(args as string[])];
      spawnedOptions = { ...options };
      return terminal.pty;
    },
  });
  await listen(server);

  const address = server.address() as AddressInfo;
  const websocket = new WebSocket(
    `ws://127.0.0.1:${address.port}/api/sessions/fixture/terminal`,
    [TERMINAL_PROTOCOL],
    { headers: { Authorization: `Bearer ${config.token}` } },
  );

  try {
    await once(websocket, "open");
    await waitUntil(() => spawnedFile !== "");
    assert.equal(spawnedFile, "tmux");
    assert.deepEqual(spawnedArgs, ["-L", "mocha", "attach-session", "-t", "fixture"]);
    assert.equal("handleFlowControl" in spawnedOptions, false);
  } finally {
    await closeWebSocket(websocket);
    await waitUntil(() => terminal.killed);
    await close(server);
  }
});

test("terminal websocket rejects missing credentials before spawning a pty", async () => {
  let spawnCount = 0;
  const server = await createMochaServer({
    config,
    tmux: {} as SessionBackend,
    spawnTerminal: (..._args) => {
      spawnCount += 1;
      return new FakeTerminal().pty;
    },
  });
  await listen(server);

  try {
    const address = server.address() as AddressInfo;
    const status = await rejectedUpgradeStatus(
      `ws://127.0.0.1:${address.port}/api/sessions/fixture/terminal`,
    );
    assert.equal(status, 401);
    assert.equal(spawnCount, 0);
  } finally {
    await close(server);
  }
});

test("terminal websocket rejects an unsupported protocol before session lookup", async () => {
  let lookupCount = 0;
  let spawnCount = 0;
  const tmux = {
    getSession: async () => {
      lookupCount += 1;
      return { id: "fixture" };
    },
  } as unknown as SessionBackend;
  const server = await createMochaServer({
    config,
    tmux,
    spawnTerminal: (..._args) => {
      spawnCount += 1;
      return new FakeTerminal().pty;
    },
  });
  await listen(server);

  try {
    const address = server.address() as AddressInfo;
    const status = await rejectedUpgradeStatus(
      `ws://127.0.0.1:${address.port}/api/sessions/fixture/terminal`,
      ["unsupported.v1"],
      { Authorization: `Bearer ${config.token}` },
    );
    assert.equal(status, 400);
    assert.equal(lookupCount, 0);
    assert.equal(spawnCount, 0);
  } finally {
    await close(server);
  }
});

test("terminal websocket returns not found before spawning a pty", async () => {
  let spawnCount = 0;
  const tmux = {
    getSession: async () => undefined,
  } as unknown as SessionBackend;
  const server = await createMochaServer({
    config,
    tmux,
    spawnTerminal: (..._args) => {
      spawnCount += 1;
      return new FakeTerminal().pty;
    },
  });
  await listen(server);

  try {
    const address = server.address() as AddressInfo;
    const status = await rejectedUpgradeStatus(
      `ws://127.0.0.1:${address.port}/api/sessions/missing/terminal`,
      [TERMINAL_PROTOCOL],
      { Authorization: `Bearer ${config.token}` },
    );
    assert.equal(status, 404);
    assert.equal(spawnCount, 0);
  } finally {
    await close(server);
  }
});

// A herdr double that satisfies the full agent source, with only the pieces
// a given test cares about overridden.
function stubHerdr(
  options: { cwd?: string; onCreateTab?: (request: HerdrTabRequest) => void } = {},
): HerdrAgentSource {
  const agent = {
    id: "wB:p1",
    agent: "claude",
    status: "idle" as const,
    cwd: options.cwd ?? "/work",
    title: "",
    workspaceId: "wB",
    tabId: "wB:t1",
    focused: false,
    revision: 1,
    authority: "herdr" as const,
  };
  return {
    listAgents: async () => ({ provider: "herdr" as const, available: true, protocol: 17, agents: [agent] }),
    listTree: async () => ({ available: true as const, workspaces: [] }),
    findAgent: async () => ({ available: true as const, agent }),
    attachCommand: (paneId: string) => ({ bin: "herdr", args: ["agent", "attach", paneId] }),
    readAgent: async () => ({ available: true as const, preview: "" }),
    readDialog: async () => ({ present: false as const }),
    decideAgent: async () => ({ decided: true as const, sent: "Enter" }),
    promptAgent: async () => ({ submitted: true as const }),
    createTab: async (request: HerdrTabRequest) => {
      options.onCreateTab?.(request);
      return { created: true as const, paneId: "wB:p9", tabId: "wB:t9" };
    },
    closeTab: async () => ({ closed: true as const }),
  };
}

async function withServer(run: (origin: string) => Promise<void>): Promise<void> {
  const server = await createMochaServer({ config, tmux: {} as SessionBackend });
  await listen(server);

  try {
    const address = server.address() as AddressInfo;
    await run(`http://127.0.0.1:${address.port}`);
  } finally {
    await close(server);
  }
}

async function openTerminalSocket(terminal: FakeTerminal): Promise<{
  server: Server;
  websocket: WebSocket;
  messages: AsyncGenerator<ServerTerminalMessage>;
}> {
  const tmux = {
    getSession: async () => ({ id: "fixture" }),
    attachCommand: (id: string) => ({ bin: "tmux", args: ["-L", "mocha", "attach-session", "-t", id] }),
  } as unknown as SessionBackend;
  const server = await createMochaServer({
    config,
    tmux,
    spawnTerminal: () => terminal.pty,
  });
  await listen(server);

  const address = server.address() as AddressInfo;
  const websocket = new WebSocket(
    `ws://127.0.0.1:${address.port}/api/sessions/fixture/terminal`,
    [TERMINAL_PROTOCOL],
    { headers: { Authorization: `Bearer ${config.token}` } },
  );
  const messages = collectMessages(websocket);
  await once(websocket, "open");
  assert.equal((await messages.next()).value?.type, "ready");
  return { server, websocket, messages };
}

function listen(server: Server): Promise<void> {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
}

function close(server: Server): Promise<void> {
  return new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}

async function closeWebSocket(websocket: WebSocket): Promise<void> {
  if (websocket.readyState === WebSocket.CLOSED) return;
  const closed = once(websocket, "close");
  if (websocket.readyState === WebSocket.OPEN) websocket.close();
  await closed;
}

function collectMessages(websocket: WebSocket): AsyncGenerator<ServerTerminalMessage> {
  const queue: ServerTerminalMessage[] = [];
  let resume: (() => void) | undefined;
  websocket.on("message", (raw) => {
    queue.push(JSON.parse(raw.toString()) as ServerTerminalMessage);
    resume?.();
    resume = undefined;
  });

  return (async function* messages() {
    while (websocket.readyState !== WebSocket.CLOSED || queue.length > 0) {
      if (queue.length === 0) {
        await new Promise<void>((resolve) => {
          resume = resolve;
        });
      }
      const message = queue.shift();
      if (message) yield message;
    }
  })();
}

async function waitUntil(condition: () => boolean): Promise<void> {
  const deadline = Date.now() + 1_000;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error("Timed out waiting for terminal event.");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

function rejectedUpgradeStatus(
  url: string,
  protocols: string[] = [TERMINAL_PROTOCOL],
  headers: Record<string, string> = {},
): Promise<number | undefined> {
  return new Promise((resolve, reject) => {
    const websocket = new WebSocket(url, protocols, { headers });
    websocket.once("unexpected-response", (_request, response) => {
      response.resume();
      resolve(response.statusCode);
    });
    websocket.once("error", reject);
  });
}

class FakeTerminal {
  readonly resizes: Array<{ columns: number; rows: number }> = [];
  readonly writes: string[] = [];
  killed = false;

  private dataListener: (data: string) => void = () => {};
  private exitListener: (event: { exitCode: number; signal?: number }) => void = () => {};

  readonly pty = {
    pid: 1,
    cols: 100,
    rows: 30,
    process: "tmux",
    handleFlowControl: true,
    onData: (listener: (data: string) => void) => {
      this.dataListener = listener;
      return { dispose: () => {} };
    },
    onExit: (listener: (event: { exitCode: number; signal?: number }) => void) => {
      this.exitListener = listener;
      return { dispose: () => {} };
    },
    resize: (columns: number, rows: number) => {
      this.resizes.push({ columns, rows });
    },
    write: (data: string) => {
      this.writes.push(data);
    },
    kill: () => {
      this.killed = true;
    },
    pause: () => {},
    resume: () => {},
    clear: () => {},
  } as IPty;

  emitData(data: string): void {
    this.dataListener(data);
  }

  emitExit(exitCode: number, signal?: number): void {
    this.exitListener({ exitCode, ...(signal === undefined ? {} : { signal }) });
  }
}
