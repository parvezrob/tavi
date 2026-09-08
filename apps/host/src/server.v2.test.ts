import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtemp } from "node:fs/promises";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import WebSocket from "ws";
import {
  close,
  closeOutcome,
  harnessConfig as config,
  FakeAgentEvents,
  TerminalHarness,
  waitUntil,
} from "./testing/terminal-harness.js";

test("v2 negotiates, streams binary output frames, and keeps the pty across reconnects for resume", async () => {
  const harness = new TerminalHarness();
  const server = await harness.startServer();

  try {
    const first = await harness.openSocket(server);
    const ready = await first.nextControl();
    assert.equal(ready.type, "ready");
    assert.equal(ready.resumed, false);
    assert.equal(ready.offset, 0);
    const stream = ready.stream;
    assert.ok(stream && stream.length > 0);

    harness.terminals[0]?.emitData("hello ");
    const outputA = await first.nextOutput();
    assert.equal(outputA.offset, 0);
    assert.equal(outputA.data, "hello ");

    first.websocket.send(JSON.stringify({ type: "input", data: "ls\r" }));
    first.websocket.send(JSON.stringify({ type: "ping", id: "beat-1" }));
    assert.deepEqual(await first.nextControl(), { type: "pong", id: "beat-1" });
    await waitUntil(() => harness.terminals[0]?.writes.length === 1);

    await first.close();
    // Output continues while no client is attached.
    harness.terminals[0]?.emitData("world");

    const second = await harness.openSocket(server, `stream=${stream}&resume=6`);
    const resumedReady = await second.nextControl();
    assert.equal(resumedReady.type, "ready");
    assert.equal(resumedReady.resumed, true);
    assert.equal(resumedReady.offset, 6);
    assert.equal(resumedReady.stream, stream);

    const replay = await second.nextOutput();
    assert.equal(replay.offset, 6);
    assert.equal(replay.data, "world");

    assert.equal(harness.spawnCount, 1);
    assert.equal(harness.terminals[0]?.killed, false);
    await second.close();
  } finally {
    await close(server);
  }
});

test("v2 resume miss falls back to a fresh attach with a new stream epoch", async () => {
  const harness = new TerminalHarness();
  const server = await harness.startServer();

  try {
    const first = await harness.openSocket(server);
    const ready = await first.nextControl();
    assert.equal(ready.type, "ready");
    harness.terminals[0]?.emitData("before");
    await first.nextOutput();
    await first.close();

    const second = await harness.openSocket(server, "stream=wrong-epoch&resume=3");
    const freshReady = await second.nextControl();
    assert.equal(freshReady.type, "ready");
    assert.equal(freshReady.resumed, false);
    assert.equal(freshReady.offset, 0);
    assert.notEqual(freshReady.stream, ready.stream);

    assert.equal(harness.spawnCount, 2);
    await waitUntil(() => harness.terminals[0]?.killed === true);
    await second.close();
  } finally {
    await close(server);
  }
});

test("v2 second connection supersedes the first on the same attachment", async () => {
  const harness = new TerminalHarness();
  const server = await harness.startServer();

  try {
    const first = await harness.openSocket(server);
    const ready = await first.nextControl();
    assert.equal(ready.type, "ready");

    const firstClosed = once(first.websocket, "close");
    const second = await harness.openSocket(server, `stream=${ready.stream}&resume=0`);
    const takeover = await second.nextControl();
    assert.equal(takeover.type, "ready");
    assert.equal(takeover.resumed, true);

    // The ownership outcome the phone reads: the machine code and the
    // sentence, then 1000 "superseded" — never a bare disconnect it would
    // retry through, and readable even if that close never arrives.
    assert.deepEqual(await first.nextControl(), {
      type: "error",
      message: "Another connection took over this terminal.",
      code: "superseded",
    });
    assert.deepEqual(await closeOutcome(firstClosed), { code: 1000, reason: "superseded" });
    assert.equal(harness.spawnCount, 1);

    harness.terminals[0]?.emitData("to the new owner");
    assert.equal((await second.nextOutput()).data, "to the new owner");
    await second.close();
  } finally {
    await close(server);
  }
});

test("v2 fresh replacement supersedes the old client and keeps the herdr pane attachable", async () => {
  const harness = new TerminalHarness();
  const server = await harness.startServer();

  try {
    const first = await harness.openSocket(server);
    const ready = await first.nextControl();
    assert.equal(ready.type, "ready");

    // No resume parameters: the fresh-attach branch, where the old attachment
    // used to be disposed while its socket stayed open and answering (#108).
    const firstClosed = once(first.websocket, "close");
    const second = await harness.openSocket(server);
    const freshReady = await second.nextControl();
    assert.equal(freshReady.type, "ready");
    assert.equal(freshReady.resumed, false);
    assert.notEqual(freshReady.stream, ready.stream);

    assert.deepEqual(await first.nextControl(), {
      type: "error",
      message: "Another connection took over this terminal.",
      code: "superseded",
    });
    assert.deepEqual(await closeOutcome(firstClosed), { code: 1000, reason: "superseded" });

    // Only the losing client's temporary attach pty ends; the new client owns
    // a second attach to the same durable pane and can drive it.
    assert.equal(harness.spawnCount, 2);
    await waitUntil(() => harness.terminals[0]?.killed === true);
    assert.equal(harness.terminals[1]?.killed, false);
    second.websocket.send(JSON.stringify({ type: "input", data: "still working\r" }));
    await waitUntil(() => harness.terminals[1]?.writes.length === 1);
    harness.terminals[1]?.emitData("to the new owner");
    assert.equal((await second.nextOutput()).data, "to the new owner");
    await second.close();
  } finally {
    await close(server);
  }
});

test("v2 exit reaches the connected client and frees the attachment", async () => {
  const harness = new TerminalHarness();
  const server = await harness.startServer();

  try {
    const socket = await harness.openSocket(server);
    const ready = await socket.nextControl();
    assert.equal(ready.type, "ready");

    const closed = once(socket.websocket, "close");
    harness.terminals[0]?.emitExit(0);
    assert.deepEqual(await socket.nextControl(), { type: "exit", code: 0 });
    const [code] = await closed;
    assert.equal(code, 1000);
  } finally {
    await close(server);
  }
});

test("herdr agents are attachable terminal targets with honest failure modes", async () => {
  const harness = new TerminalHarness();
  const spawnedCommands: Array<{ bin: string; args: string[] }> = [];
  const prompts: Array<{ paneId: string; text: string }> = [];
  const tabRequests: Array<{ agent?: string | undefined; cwd?: string | undefined }> = [];
  harness.recordSpawn = (bin, args) => spawnedCommands.push({ bin, args });
  let herdrUp = true;
  harness.herdr = {
    listAgents: async () => ({ provider: "herdr", available: true, protocol: 17, agents: [] }),
    listTree: async () =>
      herdrUp
        ? { available: true as const, workspaces: [] }
        : { available: false as const, reason: "The Herdr server is not running." },
    closeTab: async () =>
      herdrUp ? { closed: true as const } : { closed: false as const, reason: "The Herdr server is not running." },
    renameTab: async (_tabId: string, label: string) =>
      herdrUp
        ? { renamed: true as const, label }
        : { renamed: false as const, reason: "The Herdr server is not running." },
    findAgent: async (paneId: string) =>
      herdrUp
        ? paneId === "wB:p1"
          ? {
              available: true as const,
              agent: {
                id: "wB:p1",
                agent: "claude",
                status: "idle" as const,
                cwd: "/",
                title: "Claude Code",
                workspaceId: "wB",
                tabId: "wB:t1",
                focused: true,
                revision: 1,
                authority: "herdr" as const,
              },
            }
          : { available: true as const }
        : { available: false as const, reason: "The Herdr server is not running." },
    attachCommand: (paneId: string) => ({ bin: "herdr", args: ["agent", "attach", paneId] }),
    readAgent: async (paneId: string, lines: number) =>
      herdrUp
        ? { available: true as const, preview: `preview of ${paneId} (${lines} lines)` }
        : { available: false as const, reason: "The Herdr server is not running." },
    readDialog: async () =>
      herdrUp ? { present: false as const } : { available: false as const, reason: "The Herdr server is not running." },
    decideAgent: async () =>
      herdrUp
        ? { decided: true as const, sent: "Enter" }
        : { decided: false as const, reason: "The Herdr server is not running." },
    promptAgent: async (paneId: string, text: string) => {
      prompts.push({ paneId, text });
      return herdrUp
        ? { submitted: true as const }
        : { submitted: false as const, reason: "The Herdr server is not running." };
    },
    createTab: async (request: { agent?: string | undefined; cwd?: string | undefined }) => {
      tabRequests.push(request);
      return herdrUp
        ? { created: true as const, paneId: "wB:p9", tabId: "wB:t9" }
        : { created: false as const, reason: "The Herdr server is not running." };
    },
  };
  const server = await harness.startServer();

  try {
    const socket = await harness.openSocket(server, "", "/api/agents/wB:p1/terminal");
    const ready = await socket.nextControl();
    assert.equal(ready.type, "ready");
    assert.deepEqual(spawnedCommands, [{ bin: "herdr", args: ["agent", "attach", "wB:p1"] }]);

    harness.terminals[0]?.emitData("agent pane output");
    assert.equal((await socket.nextOutput()).data, "agent pane output");

    socket.websocket.send(JSON.stringify({ type: "input", data: "continue\r" }));
    await waitUntil(() => harness.terminals[0]?.writes.length === 1);
    assert.deepEqual(harness.terminals[0]?.writes, ["continue\r"]);
    await socket.close();

    assert.equal(await harness.upgradeStatus(server, "/api/agents/wB:p9/terminal"), 404);

    const address = server.address() as AddressInfo;
    const preview = await fetch(`http://127.0.0.1:${address.port}/api/agents/wB:p1/preview?lines=99`, {
      headers: { Authorization: `Bearer ${config.token}` },
    });
    assert.equal(preview.status, 200);
    assert.deepEqual(await preview.json(), {
      paneId: "wB:p1",
      lines: 50,
      preview: "preview of wB:p1 (50 lines)",
    });

    const prompt = await fetch(`http://127.0.0.1:${address.port}/api/agents/wB:p1/prompt`, {
      method: "POST",
      headers: { Authorization: `Bearer ${config.token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ text: "continue with the plan" }),
    });
    assert.equal(prompt.status, 202);
    assert.deepEqual(prompts, [{ paneId: "wB:p1", text: "continue with the plan" }]);

    const emptyPrompt = await fetch(`http://127.0.0.1:${address.port}/api/agents/wB:p1/prompt`, {
      method: "POST",
      headers: { Authorization: `Bearer ${config.token}`, "Content-Type": "application/json" },
      body: JSON.stringify({}),
    });
    assert.equal(emptyPrompt.status, 400);
    assert.equal(prompts.length, 1);

    // A real directory inside the configured roots: the host now refuses to
    // launch an agent anywhere it cannot verify (#24).
    const project = await mkdtemp(path.join(tmpdir(), "tavi-v2-project-"));
    const tab = await fetch(`http://127.0.0.1:${address.port}/api/herdr/tabs`, {
      method: "POST",
      headers: { Authorization: `Bearer ${config.token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ agent: "claude", cwd: project }),
    });
    assert.equal(tab.status, 201);
    assert.deepEqual(await tab.json(), { paneId: "wB:p9", tabId: "wB:t9" });
    assert.deepEqual(tabRequests.at(-1), {
      agent: "claude",
      cwd: project,
      label: "tavi claude",
    });

    const badTab = await fetch(`http://127.0.0.1:${address.port}/api/herdr/tabs`, {
      method: "POST",
      headers: { Authorization: `Bearer ${config.token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ agent: "rm -rf" }),
    });
    assert.equal(badTab.status, 400);

    herdrUp = false;
    assert.equal(await harness.upgradeStatus(server, "/api/agents/wB:p1/terminal"), 503);
    const downPreview = await fetch(`http://127.0.0.1:${address.port}/api/agents/wB:p1/preview`, {
      headers: { Authorization: `Bearer ${config.token}` },
    });
    assert.equal(downPreview.status, 503);
    const downPrompt = await fetch(`http://127.0.0.1:${address.port}/api/agents/wB:p1/prompt`, {
      method: "POST",
      headers: { Authorization: `Bearer ${config.token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ text: "lost" }),
    });
    assert.equal(downPrompt.status, 503);
  } finally {
    await close(server);
  }
});

test("events endpoint pushes agent snapshots and degrades honestly when unconfigured", async () => {
  const harness = new TerminalHarness();
  const agentEvents = new FakeAgentEvents();
  harness.agentEvents = agentEvents;
  const server = await harness.startServer();

  try {
    const address = server.address() as AddressInfo;
    const websocket = new WebSocket(`ws://127.0.0.1:${address.port}/api/events`, ["tavi.events.v1"], {
      headers: { Authorization: `Bearer ${config.token}` },
    });
    const messages: Array<Record<string, unknown>> = [];
    websocket.on("message", (raw) => messages.push(JSON.parse(raw.toString())));
    await once(websocket, "open");

    await waitUntil(() => messages.length === 1);
    assert.equal(messages[0]?.available, false);

    agentEvents.publish({
      available: true,
      agents: [{ id: "wB:p1", agent: "claude", status: "blocked" }],
    });
    await waitUntil(() => messages.length === 2);
    assert.equal(messages[1]?.type, "agents");
    assert.equal(messages[1]?.available, true);
    assert.equal((messages[1]?.agents as Array<{ status: string }>)?.[0]?.status, "blocked");

    websocket.close();
    await once(websocket, "close");
    await waitUntil(() => agentEvents.subscriberCount === 0);
  } finally {
    await close(server);
  }
});
