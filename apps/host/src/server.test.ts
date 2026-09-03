import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { once } from "node:events";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import test from "node:test";
import type { IPty } from "node-pty";
import WebSocket from "ws";
import { AgentKindDetector } from "./agent-kinds.js";
import { AttentionOverlay } from "./attention.js";
import { EVENTS_PROTOCOL, TERMINAL_PROTOCOL } from "./protocol.js";
import type { HerdrAgentSource, HerdrTabRequest } from "./herdr-types.js";
import { DeviceRegistry, PairingSessions } from "./pairing.js";
import { ProjectHistory } from "./projects.js";
import { createTaviServer } from "./server.js";
import { testConfig } from "./testing/config.js";
import type { ServerTerminalMessage } from "./types.js";

const config = testConfig({ port: 0 });

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
    renameTab: async (_tabId: string, label: string) => ({ renamed: true as const, label: label.trim() }),
    listTree: async () => ({
      available: true as const,
      workspaces: [
        {
          workspaceId: "wB",
          label: "~",
          focused: true,
          tabs: [{ tabId: "wB:t1", label: "tavi", focused: true, agents: [] }],
        },
      ],
    }),
  };
  const server = await createTaviServer({ config, herdr });
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

    // #55: renaming a tab wraps herdr's tab.rename; blank labels never
    // reach herdr.
    const renamed = await fetch(`http://127.0.0.1:${address.port}/api/herdr/tabs/wB:t9`, {
      method: "PATCH",
      headers: { Authorization: `Bearer ${config.token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ label: "  ship the fix  " }),
    });
    assert.equal(renamed.status, 200);
    assert.deepEqual(await renamed.json(), { renamed: true, tabId: "wB:t9", label: "ship the fix" });

    const blankRename = await fetch(`http://127.0.0.1:${address.port}/api/herdr/tabs/wB:t9`, {
      method: "PATCH",
      headers: { Authorization: `Bearer ${config.token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ label: "   " }),
    });
    assert.equal(blankRename.status, 400);
  } finally {
    await close(server);
  }

  const bareServer = await createTaviServer({ config });
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
    renameTab: async (_tabId: string, label: string) => ({ renamed: true as const, label }),
  };
  const server = await createTaviServer({ config, herdr, attention });
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
    renameTab: async (_tabId: string, label: string) => ({ renamed: true as const, label }),
  };
  const server = await createTaviServer({ config, herdr, attention });
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

test("a phone pairs with a single-use code and gets a credential of its own (#45, #46)", async () => {
  const stateDir = mkdtempSync(path.join(tmpdir(), "tavi-pair-state-"));
  const devices = new DeviceRegistry(stateDir, undefined, () => {});
  const pairing = new PairingSessions();
  const server = await createTaviServer({ config, devices, pairing });
  await listen(server);

  try {
    const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
    const json = { "Content-Type": "application/json" };

    // Only the host's own token may mint a code.
    const forbidden = await fetch(`${base}/api/pair/begin`, { method: "POST" });
    assert.equal(forbidden.status, 401);
    const begun = await fetch(`${base}/api/pair/begin`, {
      method: "POST",
      headers: { Authorization: `Bearer ${config.token}` },
    });
    assert.equal(begun.status, 201);
    const { secret, host } = (await begun.json()) as { secret: string; host: { name: string; fingerprint: string } };
    assert.equal(host.name, "test-host");
    assert.equal(host.fingerprint, devices.identity().fingerprint);

    // A wrong code is refused without authentication being involved.
    const wrong = await fetch(`${base}/api/pair`, {
      method: "POST",
      headers: json,
      body: JSON.stringify({ secret: "nope", deviceName: "Intruder" }),
    });
    assert.equal(wrong.status, 401);

    const paired = await fetch(`${base}/api/pair`, {
      method: "POST",
      headers: json,
      body: JSON.stringify({ secret, deviceName: "Parvez's iPhone" }),
    });
    assert.equal(paired.status, 201);
    const grant = (await paired.json()) as {
      credential: string;
      device: { id: string; name: string };
      host: { fingerprint: string };
    };
    assert.equal(grant.device.name, "Parvez's iPhone");
    assert.equal(grant.host.fingerprint, host.fingerprint);
    assert.notEqual(grant.credential, config.token);

    // The code is spent.
    const reused = await fetch(`${base}/api/pair`, {
      method: "POST",
      headers: json,
      body: JSON.stringify({ secret, deviceName: "Again" }),
    });
    assert.equal(reused.status, 401);

    // The phone's credential works everywhere the host token does…
    const asPhone = await fetch(`${base}/api/host`, {
      headers: { Authorization: `Bearer ${grant.credential}` },
    });
    assert.equal(asPhone.status, 200);
    assert.equal(((await asPhone.json()) as { fingerprint: string }).fingerprint, host.fingerprint);
    // …except minting more codes.
    const phoneMints = await fetch(`${base}/api/pair/begin`, {
      method: "POST",
      headers: { Authorization: `Bearer ${grant.credential}` },
    });
    assert.equal(phoneMints.status, 403);

    // The host can list and revoke; a phone can see neither, but can leave.
    const listed = await fetch(`${base}/api/devices`, { headers: { Authorization: `Bearer ${config.token}` } });
    assert.equal(listed.status, 200);
    assert.deepEqual(
      ((await listed.json()) as { devices: Array<{ id: string }> }).devices.map((d) => d.id),
      [grant.device.id],
    );
    const phoneLists = await fetch(`${base}/api/devices`, { headers: { Authorization: `Bearer ${grant.credential}` } });
    assert.equal(phoneLists.status, 403);
    const hostLeaves = await fetch(`${base}/api/devices/me`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${config.token}` },
    });
    assert.equal(hostLeaves.status, 400);

    // Revoking on the host cuts that phone and only that phone.
    const revokedByHost = await fetch(`${base}/api/devices/${grant.device.id}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${config.token}` },
    });
    assert.equal(revokedByHost.status, 204);
    const again = await fetch(`${base}/api/devices/${grant.device.id}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${config.token}` },
    });
    assert.equal(again.status, 404);
    const revoked = await fetch(`${base}/api/host`, {
      headers: { Authorization: `Bearer ${grant.credential}` },
    });
    assert.equal(revoked.status, 401);
    const stillHost = await fetch(`${base}/api/host`, {
      headers: { Authorization: `Bearer ${config.token}` },
    });
    assert.equal(stillHost.status, 200);

    // A phone can unpair itself, and is gone the moment it does.
    const second = devices.add("second phone");
    const left = await fetch(`${base}/api/devices/me`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${second.credential}` },
    });
    assert.equal(left.status, 204);
    assert.equal(devices.authorize(second.credential), undefined);
  } finally {
    await close(server);
  }
});

test("revoking a phone closes its open event stream within the recheck interval (#46)", async () => {
  const devices = new DeviceRegistry(mkdtempSync(path.join(tmpdir(), "tavi-revoke-")), undefined, () => {});
  const { device, credential } = devices.add("phone");
  const server = await createTaviServer({
    config,
    devices,
    authorizationRecheckMs: 20,
  });
  await listen(server);

  try {
    const port = (server.address() as AddressInfo).port;
    const websocket = new WebSocket(`ws://127.0.0.1:${port}/api/events`, EVENTS_PROTOCOL, {
      headers: { Authorization: `Bearer ${credential}` },
    });
    await once(websocket, "open");
    const closed = once(websocket, "close");

    devices.revoke(device.id);
    const [code, reason] = (await closed) as [number, Buffer];
    assert.equal(code, 4401);
    assert.equal(reason.toString(), "credential revoked");
  } finally {
    await close(server);
  }
});

test("closing the server drops open event streams instead of waiting for them (#21)", async () => {
  const server = await createTaviServer({ config });
  await listen(server);
  const port = (server.address() as AddressInfo).port;
  const websocket = new WebSocket(`ws://127.0.0.1:${port}/api/events`, EVENTS_PROTOCOL, {
    headers: { Authorization: `Bearer ${config.token}` },
  });
  await once(websocket, "open");
  const closed = once(websocket, "close");

  // A phone with the app open holds this stream for hours; a close that waits
  // for it never finishes, and the installer bootstraps into a live label.
  const started = Date.now();
  await close(server);
  const [code, reason] = (await closed) as [number, Buffer];

  assert.equal(code, 1001);
  assert.equal(reason.toString(), "host restarting");
  assert.ok(Date.now() - started < 1_000, "close must not wait on the client");
});

test("the project picker serves live agent folders, remembered choices, and roots", async () => {
  const stateDir = mkdtempSync(path.join(tmpdir(), "tavi-picker-state-"));
  const root = mkdtempSync(path.join(tmpdir(), "tavi-picker-root-"));
  // Both folders exist on disk: the picker never offers one that is gone.
  const api = path.join(root, "api");
  const web = path.join(root, "web");
  mkdirSync(api);
  mkdirSync(web);
  const projects = new ProjectHistory(stateDir);
  projects.remember(api);

  const herdr = stubHerdr({ cwd: web });
  const server = await createTaviServer({
    config: { ...config, roots: [root] },
    listWorkspaces: async () => [{ name: "api", path: api, git: true }],
    herdr,
    projects,
    agentKinds: new AgentKindDetector({ shell: "/bin/sh", runShell: async () => "codex\n" }),
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
      agents: Array<{ kind: string; label: string; installed: boolean }>;
    };

    // The folder an agent is living in leads; the remembered one follows.
    assert.deepEqual(
      body.recent.map((entry) => entry.path),
      [web, api],
    );
    assert.deepEqual(
      body.recent.map((entry) => entry.active),
      [true, false],
    );
    assert.equal(
      body.recent.every((entry) => entry.withinRoots),
      true,
    );
    assert.deepEqual(body.workspaces, [{ name: "api", path: api, git: true }]);
    assert.deepEqual(body.roots, [root]);
    // Every kind herdr supports is offered; only what this Mac has is installed.
    assert.equal(body.agents.find((entry) => entry.kind === "codex")?.installed, true);
    assert.equal(body.agents.find((entry) => entry.kind === "claude")?.installed, false);
    assert.equal(body.agents.find((entry) => entry.kind === "gemini")?.label, "Gemini CLI");

    const unauthorized = await fetch(`http://127.0.0.1:${address.port}/api/projects`);
    assert.equal(unauthorized.status, 401);
  } finally {
    await close(server);
  }
});

test("creating an agent requires a real folder and confirmation outside the roots", async () => {
  const stateDir = mkdtempSync(path.join(tmpdir(), "tavi-create-state-"));
  const root = mkdtempSync(path.join(tmpdir(), "tavi-create-root-"));
  const project = mkdtempSync(path.join(root, "repo-"));
  const outside = mkdtempSync(path.join(tmpdir(), "tavi-create-outside-"));
  const projects = new ProjectHistory(stateDir);

  const created: Array<{ agent?: string | undefined; cwd?: string | undefined }> = [];
  const herdr = stubHerdr({
    onCreateTab: (request) => {
      created.push({ agent: request.agent, cwd: request.cwd });
    },
  });
  const server = await createTaviServer({
    config: { ...config, roots: [root] },
    herdr,
    projects,
    agentKinds: new AgentKindDetector({
      shell: "/bin/sh",
      runShell: async () => "claude\ncodex\ngemini\n",
    }),
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
    assert.deepEqual(
      projects.list().map((entry) => entry.path),
      [project],
    );

    // Outside a root with the confirmation the phone sends after asking.
    const confirmed = await create({ agent: "codex", cwd: outside, allowOutsideRoots: true });
    assert.equal(confirmed.status, 201);
    assert.deepEqual(created.at(-1), { agent: "codex", cwd: outside });
    assert.deepEqual(
      projects.list().map((entry) => entry.path),
      [outside, project],
    );

    // Any kind herdr can launch is accepted, not just the first two; anything
    // else is refused before herdr sees it.
    const gemini = await create({ agent: "gemini", cwd: project });
    assert.equal(gemini.status, 201);
    assert.deepEqual(created.at(-1), { agent: "gemini", cwd: project });
    const bogus = await create({ agent: "rm -rf", cwd: project });
    assert.equal(bogus.status, 400);
    // A real kind that this Mac does not have is refused before herdr sees
    // it — herdr would otherwise hand back a tab whose launch already died.
    // A plain terminal needs nothing installed and is labelled as one.
    const terminal = await create({ agent: "shell", cwd: project });
    assert.equal(terminal.status, 201);
    assert.deepEqual(created.at(-1), { agent: "shell", cwd: project });

    const notInstalled = await create({ agent: "cursor", cwd: project });
    assert.equal(notInstalled.status, 400);
    assert.match(((await notInstalled.json()) as { error: string }).error, /Cursor is not installed/);
    assert.equal(created.length, 4);
  } finally {
    await close(server);
  }
});

test("terminal websocket authenticates and bridges typed protocol messages", async () => {
  const terminal = new FakeTerminal();
  const herdr = terminalHerdr();
  const server = await createTaviServer({
    config,
    herdr,
    spawnTerminal: () => terminal.pty,
  });
  await listen(server);

  const address = server.address() as AddressInfo;
  const websocket = new WebSocket(`ws://127.0.0.1:${address.port}/api/agents/fixture/terminal`, [TERMINAL_PROTOCOL], {
    headers: { Authorization: `Bearer ${config.token}` },
  });
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
  const herdr = terminalHerdr();
  const server = await createTaviServer({
    config,
    herdr,
    spawnTerminal: (file, args, options) => {
      spawnedFile = file;
      spawnedArgs = [...(args as string[])];
      spawnedOptions = { ...options };
      return terminal.pty;
    },
  });
  await listen(server);

  const address = server.address() as AddressInfo;
  const websocket = new WebSocket(`ws://127.0.0.1:${address.port}/api/agents/fixture/terminal`, [TERMINAL_PROTOCOL], {
    headers: { Authorization: `Bearer ${config.token}` },
  });

  try {
    await once(websocket, "open");
    await waitUntil(() => spawnedFile !== "");
    assert.equal(spawnedFile, "herdr");
    assert.deepEqual(spawnedArgs, ["agent", "attach", "fixture"]);
    assert.equal("handleFlowControl" in spawnedOptions, false);
  } finally {
    await closeWebSocket(websocket);
    await waitUntil(() => terminal.killed);
    await close(server);
  }
});

test("terminal websocket rejects missing credentials before spawning a pty", async () => {
  let spawnCount = 0;
  const server = await createTaviServer({
    config,
    spawnTerminal: (..._args) => {
      spawnCount += 1;
      return new FakeTerminal().pty;
    },
  });
  await listen(server);

  try {
    const address = server.address() as AddressInfo;
    const status = await rejectedUpgradeStatus(`ws://127.0.0.1:${address.port}/api/agents/fixture/terminal`);
    assert.equal(status, 401);
    assert.equal(spawnCount, 0);
  } finally {
    await close(server);
  }
});

test("terminal websocket rejects an unsupported protocol before pane lookup", async () => {
  let lookupCount = 0;
  let spawnCount = 0;
  const herdr = terminalHerdr({
    onLookup: () => {
      lookupCount += 1;
    },
  });
  const server = await createTaviServer({
    config,
    herdr,
    spawnTerminal: (..._args) => {
      spawnCount += 1;
      return new FakeTerminal().pty;
    },
  });
  await listen(server);

  try {
    const address = server.address() as AddressInfo;
    const status = await rejectedUpgradeStatus(
      `ws://127.0.0.1:${address.port}/api/agents/fixture/terminal`,
      ["unsupported.v1"],
      {
        Authorization: `Bearer ${config.token}`,
      },
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
  const herdr = terminalHerdr({ known: [] });
  const server = await createTaviServer({
    config,
    herdr,
    spawnTerminal: (..._args) => {
      spawnCount += 1;
      return new FakeTerminal().pty;
    },
  });
  await listen(server);

  try {
    const address = server.address() as AddressInfo;
    const status = await rejectedUpgradeStatus(
      `ws://127.0.0.1:${address.port}/api/agents/missing/terminal`,
      [TERMINAL_PROTOCOL],
      {
        Authorization: `Bearer ${config.token}`,
      },
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
  options: {
    cwd?: string;
    onCreateTab?: (request: HerdrTabRequest) => void;
    onRenameTab?: (tabId: string, label: string) => void;
  } = {},
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
    renameTab: async (tabId: string, label: string) => {
      options.onRenameTab?.(tabId, label);
      return { renamed: true as const, label };
    },
    createTab: async (request: HerdrTabRequest) => {
      options.onCreateTab?.(request);
      return { created: true as const, paneId: "wB:p9", tabId: "wB:t9" };
    },
    closeTab: async () => ({ closed: true as const }),
  };
}

// A herdr that knows the given pane ids and attaches through the herdr CLI
// — the terminal bridge's only backend.
function terminalHerdr(options: { known?: string[]; onLookup?: () => void } = {}): HerdrAgentSource {
  const known = options.known ?? ["fixture"];
  const base = stubHerdr();
  return {
    ...base,
    findAgent: async (paneId: string) => {
      options.onLookup?.();
      const agent = (await base.listAgents()).agents[0];
      return known.includes(paneId) && agent
        ? { available: true as const, agent: { ...agent, id: paneId } }
        : { available: true as const };
    },
  };
}

async function withServer(run: (origin: string) => Promise<void>): Promise<void> {
  const server = await createTaviServer({ config });
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
  const herdr = terminalHerdr();
  const server = await createTaviServer({
    config,
    herdr,
    spawnTerminal: () => terminal.pty,
  });
  await listen(server);

  const address = server.address() as AddressInfo;
  const websocket = new WebSocket(`ws://127.0.0.1:${address.port}/api/agents/fixture/terminal`, [TERMINAL_PROTOCOL], {
    headers: { Authorization: `Bearer ${config.token}` },
  });
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
    process: "herdr",
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

test("read-only file routes: auth required, roots enforced after realpath, content served, raw for images only (#57 #61 #25)", async () => {
  const base = mkdtempSync(path.join(tmpdir(), "tavi-files-route-"));
  const root = path.join(base, "Projects");
  const outside = path.join(base, "outside");
  mkdirSync(path.join(root, "app"), { recursive: true });
  mkdirSync(outside);
  writeFileSync(path.join(root, "app", "notes.md"), "# notes\n");
  writeFileSync(path.join(outside, "settings.json"), "{}\n");
  symlinkSync(path.join(outside, "settings.json"), path.join(root, "app", "link.json"));
  writeFileSync(path.join(root, "app", "pixel.png"), Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x00]));

  const server = await createTaviServer({ config: { ...config, roots: [root] } });
  await listen(server);
  try {
    const address = server.address() as AddressInfo;
    const origin = `http://127.0.0.1:${address.port}`;
    const headers = { Authorization: `Bearer ${config.token}` };
    const cwd = encodeURIComponent(path.join(root, "app"));

    assert.equal((await fetch(`${origin}/api/files/content?cwd=${cwd}&path=notes.md`)).status, 401);

    const content = await fetch(`${origin}/api/files/content?cwd=${cwd}&path=notes.md`, { headers });
    assert.equal(content.status, 200);
    const body = (await content.json()) as { content: string; relativePath: string; mime: string };
    assert.equal(body.content, "# notes\n");
    assert.equal(body.relativePath, "notes.md");
    assert.equal(body.mime, "text/markdown");

    const escaped = await fetch(`${origin}/api/files/content?cwd=${cwd}&path=link.json`, { headers });
    assert.equal(escaped.status, 403);
    assert.deepEqual(await escaped.json(), { error: "That file is outside your project folders.", outsideRoots: true });

    const absoluteOutside = await fetch(
      `${origin}/api/files/stat?cwd=${cwd}&path=${encodeURIComponent(path.join(outside, "settings.json"))}`,
      { headers },
    );
    assert.equal(absoluteOutside.status, 403);

    const listing = await fetch(`${origin}/api/files?cwd=${cwd}&path=.`, { headers });
    assert.equal(listing.status, 200);
    const entries = ((await listing.json()) as { entries: { name: string }[] }).entries.map((entry) => entry.name);
    assert.deepEqual(entries, ["link.json", "notes.md", "pixel.png"]);

    const raw = await fetch(`${origin}/api/files/raw?cwd=${cwd}&path=pixel.png`, { headers });
    assert.equal(raw.status, 200);
    assert.equal(raw.headers.get("content-type"), "image/png");
    assert.equal((await raw.arrayBuffer()).byteLength, 5);
    const rawText = await fetch(`${origin}/api/files/raw?cwd=${cwd}&path=notes.md`, { headers });
    assert.equal(rawText.status, 415);

    const changes = await fetch(`${origin}/api/changes?cwd=${cwd}`, { headers });
    assert.equal(changes.status, 404);
    assert.equal(((await changes.json()) as { notRepository?: true }).notRepository, true);
    const changesOutside = await fetch(`${origin}/api/changes?cwd=${encodeURIComponent(outside)}`, { headers });
    assert.equal(changesOutside.status, 403);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test("repos endpoint reports worktrees with branch and dirty state (#59a)", async () => {
  const base = realpathSync(mkdtempSync(path.join(tmpdir(), "tavi-repos-route-")));
  const repoDir = path.join(base, "app");
  execFileSync("git", ["init", "-q", "-b", "main", repoDir]);
  writeFileSync(path.join(repoDir, "README.md"), "# app\n");
  execFileSync("git", ["-C", repoDir, "add", "."]);
  execFileSync("git", ["-C", repoDir, "commit", "-q", "-m", "init"], {
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: "t",
      GIT_AUTHOR_EMAIL: "t@t",
      GIT_COMMITTER_NAME: "t",
      GIT_COMMITTER_EMAIL: "t@t",
    },
  });

  const server = await createTaviServer({ config: { ...config, roots: [base] }, pullRequests: async () => null });
  await listen(server);
  try {
    const address = server.address() as AddressInfo;
    const origin = `http://127.0.0.1:${address.port}`;

    assert.equal((await fetch(`${origin}/api/repos`)).status, 401);

    const response = await fetch(`${origin}/api/repos`, { headers: { Authorization: `Bearer ${config.token}` } });
    assert.equal(response.status, 200);
    const body = (await response.json()) as {
      repos: { root: string; worktrees: { branch: string | null; isMain: boolean }[] }[];
    };
    const repo = body.repos.find((entry) => entry.root === repoDir);
    assert.ok(repo, "expected the repository to be reported");
    assert.deepEqual(
      repo?.worktrees.map((w) => [w.branch, w.isMain]),
      [["main", true]],
    );
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

// --- dev-server preview (#58) -----------------------------------------------

test("preview: door status, candidates, open/keepalive/close scoped to the device, stop server", async () => {
  const root = realpathSync(mkdtempSync(path.join(tmpdir(), "tavi-preview-root-")));
  const project = path.join(root, "web");
  mkdirSync(project);
  const stateDir = mkdtempSync(path.join(tmpdir(), "tavi-preview-state-"));
  const devices = new DeviceRegistry(stateDir);
  const phoneA = devices.add("Phone A").credential;
  const phoneB = devices.add("Phone B").credential;
  let doorUp = false;
  const killed: number[] = [];
  const { PreviewRegistry } = await import("./preview.js");
  const previews = new PreviewRegistry({ probe: async (port) => (port === 5173 ? "127.0.0.1" : undefined) });
  const server = await createTaviServer({
    config: { ...config, roots: [root], port: 8787 },
    devices,
    previews,
    doorReady: async () => doorUp,
    discovery: {
      // 8787 is the host's own API port: never offered, even from inside the project.
      listListeners: async () =>
        "p42\ncnode\nf3\nn127.0.0.1:5173\np43\ncnode\nf3\nn127.0.0.1:4000\np44\ncnode\nf3\nn127.0.0.1:8787\n",
      listCwds: async () => `p42\nfcwd\nn${project}\np43\nfcwd\nn/tmp\np44\nfcwd\nn${project}\n`,
      realpath: async (target: string) => target,
      kill: (pid: number) => killed.push(pid),
    },
  });
  await listen(server);
  const origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const as = (credential: string, init: RequestInit = {}) => ({
    ...init,
    headers: { ...(init.headers ?? {}), Authorization: `Bearer ${credential}`, "Content-Type": "application/json" },
  });

  try {
    assert.equal((await fetch(`${origin}/api/preview/door`)).status, 401, "bearer token required");
    const door = await fetch(`${origin}/api/preview/door`, as(phoneA));
    assert.deepEqual(await door.json(), { doorPort: 8443, ready: false, cookieName: "tavi_preview" });

    const candidates = await fetch(`${origin}/api/preview/candidates?cwd=${encodeURIComponent(project)}`, as(phoneA));
    assert.deepEqual(await candidates.json(), {
      available: true,
      servers: [{ port: 5173, command: "node", cwd: project }],
    });
    const outside = await fetch(`${origin}/api/preview/candidates?cwd=${encodeURIComponent("/tmp")}`, as(phoneA));
    assert.equal(outside.status, 403);

    // The door is not published yet: say what to run, mint nothing.
    const noDoor = await fetch(
      `${origin}/api/preview`,
      as(phoneA, { method: "POST", body: JSON.stringify({ cwd: project, port: 5173 }) }),
    );
    assert.equal(noDoor.status, 409);
    assert.equal(((await noDoor.json()) as { doorMissing?: boolean }).doorMissing, true);
    assert.equal(previews.size, 0);

    doorUp = true;
    const dead = await fetch(
      `${origin}/api/preview`,
      as(phoneA, { method: "POST", body: JSON.stringify({ cwd: project, port: 4000 }) }),
    );
    assert.equal(dead.status, 409);
    assert.match(((await dead.json()) as { error: string }).error, /Nothing is listening on localhost:4000/);

    const opened = await fetch(
      `${origin}/api/preview`,
      as(phoneA, { method: "POST", body: JSON.stringify({ cwd: project, port: 5173 }) }),
    );
    assert.equal(opened.status, 201);
    const body = (await opened.json()) as {
      id: string;
      port: number;
      doorPort: number;
      cookieName: string;
      ticket: string;
    };
    assert.equal(body.port, 5173);
    assert.equal(body.doorPort, 8443);
    assert.equal(body.cookieName, "tavi_preview");
    assert.match(body.ticket, /^[A-Za-z0-9_-]{43}$/);
    assert.equal(previews.admit(body.ticket)?.id, body.id);

    const alive = await fetch(`${origin}/api/preview/${body.id}/keepalive`, as(phoneA, { method: "POST" }));
    assert.deepEqual(await alive.json(), { id: body.id, port: 5173, listening: true });
    // Phone B never sees phone A's preview.
    assert.equal(
      (await fetch(`${origin}/api/preview/${body.id}/keepalive`, as(phoneB, { method: "POST" }))).status,
      404,
    );
    assert.equal((await fetch(`${origin}/api/preview/${body.id}`, as(phoneB, { method: "DELETE" }))).status, 404);
    assert.equal((await fetch(`${origin}/api/preview/${body.id}`, as(phoneA, { method: "DELETE" }))).status, 204);
    assert.equal(previews.admit(body.ticket), undefined);
    assert.equal(
      (await fetch(`${origin}/api/preview/${body.id}/keepalive`, as(phoneA, { method: "POST" }))).status,
      404,
    );

    const stopStranger = await fetch(
      `${origin}/api/preview/stop`,
      as(phoneA, { method: "POST", body: JSON.stringify({ cwd: project, port: 4000 }) }),
    );
    assert.equal(stopStranger.status, 404);
    const stopped = await fetch(
      `${origin}/api/preview/stop`,
      as(phoneA, { method: "POST", body: JSON.stringify({ cwd: project, port: 5173 }) }),
    );
    assert.deepEqual(await stopped.json(), { stopped: true, pid: 42, command: "node" });
    assert.deepEqual(killed, [42]);
  } finally {
    await close(server);
  }
});

// The worktree routes over HTTP (#81 review): the roots check and the
// confirm shape are the whole guardrail, so they are asserted here, not
// only in the modules.
test("worktree routes: 401 without a credential, 403 outside the roots, 400 without confirm, 409 for the main checkout", async () => {
  const base = realpathSync(mkdtempSync(path.join(tmpdir(), "tavi-wt-route-")));
  const repoDir = path.join(base, "app");
  const gitEnv = {
    ...process.env,
    GIT_AUTHOR_NAME: "t",
    GIT_AUTHOR_EMAIL: "t@t",
    GIT_COMMITTER_NAME: "t",
    GIT_COMMITTER_EMAIL: "t@t",
  };
  execFileSync("git", ["init", "-q", "-b", "main", repoDir]);
  writeFileSync(path.join(repoDir, "README.md"), "# app\n");
  execFileSync("git", ["-C", repoDir, "add", "."]);
  execFileSync("git", ["-C", repoDir, "commit", "-q", "-m", "init"], { env: gitEnv });
  const outside = realpathSync(mkdtempSync(path.join(tmpdir(), "tavi-wt-outside-")));
  execFileSync("git", ["init", "-q", "-b", "main", outside]);

  const server = await createTaviServer({
    config: { ...config, roots: [base] },
    pullRequests: async () => null,
    gh: async () => ({ stdout: "[]" }),
  });
  await listen(server);
  try {
    const address = server.address() as AddressInfo;
    const origin = `http://127.0.0.1:${address.port}`;
    const headers = { Authorization: `Bearer ${config.token}`, "Content-Type": "application/json" };
    const del = (body: unknown, auth = true) =>
      fetch(`${origin}/api/worktrees`, {
        method: "DELETE",
        headers: auth ? headers : { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });

    for (const route of [
      "/api/worktrees/status",
      "/api/worktrees/log",
      "/api/worktrees/removal",
      "/api/worktrees/pull-request",
    ]) {
      assert.equal((await fetch(`${origin}${route}?path=${encodeURIComponent(repoDir)}`)).status, 401, route);
    }
    assert.equal((await del({ path: repoDir, confirm: { uncommitted: 0, unpushed: 0 } }, false)).status, 401);

    const outsideRemoval = await fetch(`${origin}/api/worktrees/removal?path=${encodeURIComponent(outside)}`, {
      headers,
    });
    assert.equal(outsideRemoval.status, 403);
    assert.equal(((await outsideRemoval.json()) as { outsideRoots?: boolean }).outsideRoots, true);
    const outsideDelete = await del({ path: outside, confirm: { uncommitted: 0, unpushed: 0 } });
    assert.equal(outsideDelete.status, 403);
    assert.ok(existsSync(path.join(outside, ".git")));

    const noConfirm = await del({ path: repoDir });
    assert.equal(noConfirm.status, 400);
    const badConfirm = await del({ path: repoDir, confirm: { uncommitted: "0", unpushed: 0 } });
    assert.equal(badConfirm.status, 400);

    const removal = await fetch(`${origin}/api/worktrees/removal?path=${encodeURIComponent(repoDir)}`, { headers });
    assert.equal(removal.status, 200);
    assert.equal(((await removal.json()) as { isMain: boolean }).isMain, true);
    const main = await del({ path: repoDir, confirm: { uncommitted: 0, unpushed: 0 } });
    assert.equal(main.status, 409);
    assert.match(((await main.json()) as { error: string }).error, /main checkout/);
    assert.ok(existsSync(path.join(repoDir, "README.md")));

    const status = await fetch(`${origin}/api/worktrees/status?path=${encodeURIComponent(repoDir)}`, { headers });
    assert.equal(status.status, 200);
    const notRepo = await fetch(`${origin}/api/worktrees/status?path=${encodeURIComponent(base)}`, { headers });
    assert.equal(notRepo.status, 404);
    assert.equal(((await notRepo.json()) as { notRepository?: boolean }).notRepository, true);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test("GET /api/host names the caller's path per the computer's Tailscale, and unknown when it cannot say (#86)", async () => {
  const status = {
    Self: { TailscaleIPs: ["100.70.236.37"] },
    Peer: { k1: { TailscaleIPs: ["100.102.71.0"], CurAddr: "", Relay: "blr" } },
  };
  const server = await createTaviServer({ config, tailscale: async () => ({ stdout: JSON.stringify(status) }) });
  await listen(server);
  try {
    const address = server.address() as AddressInfo;
    // The first probe answers at once with unknown while the lookup runs;
    // the next one has the answer.
    const first = await fetch(`http://127.0.0.1:${address.port}/api/host`, {
      headers: { Authorization: `Bearer ${config.token}`, "X-Forwarded-For": "100.102.71.0" },
    });
    assert.equal(first.status, 200);
    await new Promise((resolve) => setTimeout(resolve, 20));
    const viaServe = await fetch(`http://127.0.0.1:${address.port}/api/host`, {
      headers: { Authorization: `Bearer ${config.token}`, "X-Forwarded-For": "100.102.71.0" },
    });
    assert.deepEqual(((await viaServe.json()) as { connection: unknown }).connection, { path: "relay", relay: "blr" });

    const local = await fetch(`http://127.0.0.1:${address.port}/api/host`, {
      headers: { Authorization: `Bearer ${config.token}` },
    });
    assert.deepEqual(((await local.json()) as { connection: unknown }).connection, { path: "unknown" });
  } finally {
    await close(server);
  }
});

test("POST /api/files/upload saves an image into the agent's folder and refuses the rest (#88)", async () => {
  const root = realpathSync(mkdtempSync(path.join(tmpdir(), "tavi-upload-route-")));
  const project = path.join(root, "app");
  mkdirSync(project);
  const server = await createTaviServer({ config: { ...config, roots: [root] } });
  await listen(server);
  try {
    const address = server.address() as AddressInfo;
    const base = `http://127.0.0.1:${address.port}`;
    const auth = { Authorization: `Bearer ${config.token}` };
    const saved = await fetch(`${base}/api/files/upload?cwd=${encodeURIComponent(project)}`, {
      method: "POST",
      headers: { ...auth, "Content-Type": "image/jpeg" },
      body: Buffer.from("jpeg-bytes"),
    });
    assert.equal(saved.status, 201);
    const body = (await saved.json()) as { path: string; bytes: number };
    assert.ok(body.path.startsWith(path.join(project, ".tavi", "uploads")));
    assert.ok(existsSync(body.path));
    assert.equal(body.bytes, 10);

    const text = await fetch(`${base}/api/files/upload?cwd=${encodeURIComponent(project)}`, {
      method: "POST",
      headers: { ...auth, "Content-Type": "text/plain" },
      body: "hello",
    });
    assert.equal(text.status, 415);

    const outside = await fetch(`${base}/api/files/upload?cwd=${encodeURIComponent(tmpdir())}`, {
      method: "POST",
      headers: { ...auth, "Content-Type": "image/png" },
      body: Buffer.from("x"),
    });
    assert.equal(outside.status, 403);

    const anonymous = await fetch(`${base}/api/files/upload?cwd=${encodeURIComponent(project)}`, {
      method: "POST",
      headers: { "Content-Type": "image/png" },
      body: Buffer.from("x"),
    });
    assert.equal(anonymous.status, 401);
  } finally {
    await close(server);
  }
});
