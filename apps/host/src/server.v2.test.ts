import assert from "node:assert/strict";
import { once } from "node:events";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import type { IPty } from "node-pty";
import WebSocket from "ws";
import type { HostConfig } from "./config.js";
import { OUTPUT_FRAME_HEADER_BYTES, OUTPUT_FRAME_TYPE, TERMINAL_PROTOCOL_V2 } from "./protocol.js";
import { createMochaServer, type MochaServerOptions } from "./server.js";
import type { ServerTerminalMessage, SessionBackend } from "./types.js";

const config: HostConfig = {
  bindHost: "127.0.0.1",
  port: 0,
  token: "test-token-that-is-long-enough",
  shell: "/bin/zsh",
  tmuxBin: "tmux",
  herdrSocket: path.join(tmpdir(), "mocha-v2-test-herdr.sock"),
  roots: [tmpdir()],
  stateDir: tmpdir(),
  machineName: "Test",
};

type V2Event =
  | { kind: "control"; message: ServerTerminalMessage }
  | { kind: "output"; offset: number; data: string };

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

    await firstClosed;
    assert.equal(harness.spawnCount, 1);

    harness.terminals[0]?.emitData("to the new owner");
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
  harness.recordSpawn = (bin, args) => spawnedCommands.push({ bin, args });
  let herdrUp = true;
  harness.herdr = {
    listAgents: async () => ({ provider: "herdr", available: true, protocol: 17, agents: [] }),
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
    herdrUp = false;
    assert.equal(await harness.upgradeStatus(server, "/api/agents/wB:p1/terminal"), 503);
  } finally {
    await close(server);
  }
});

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

class TerminalHarness {
  readonly terminals: FakeTerminal[] = [];
  herdr: MochaServerOptions["herdr"];
  recordSpawn: ((bin: string, args: string[]) => void) | undefined;

  get spawnCount(): number {
    return this.terminals.length;
  }

  async startServer(): Promise<Server> {
    const tmux = {
      getSession: async () => ({ id: "fixture" }),
      attachCommand: (id: string) => ({ bin: "tmux", args: ["attach-session", "-t", id] }),
    } as unknown as SessionBackend;
    const server = await createMochaServer({
      config,
      tmux,
      ...(this.herdr ? { herdr: this.herdr } : {}),
      spawnTerminal: (bin, args) => {
        this.recordSpawn?.(bin as string, args as string[]);
        const terminal = new FakeTerminal();
        this.terminals.push(terminal);
        return terminal.pty;
      },
      attachmentRetentionMs: 5_000,
    });
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
    return server;
  }

  async openSocket(
    server: Server,
    query = "",
    path = "/api/sessions/fixture/terminal",
  ): Promise<V2Socket> {
    const address = server.address() as AddressInfo;
    const suffix = query ? `?${query}` : "";
    const websocket = new WebSocket(
      `ws://127.0.0.1:${address.port}${path}${suffix}`,
      [TERMINAL_PROTOCOL_V2],
      { headers: { Authorization: `Bearer ${config.token}` } },
    );
    const socket = new V2Socket(websocket);
    await once(websocket, "open");
    assert.equal(websocket.protocol, TERMINAL_PROTOCOL_V2);
    return socket;
  }

  upgradeStatus(server: Server, path: string): Promise<number | undefined> {
    const address = server.address() as AddressInfo;
    return new Promise((resolve, reject) => {
      const websocket = new WebSocket(`ws://127.0.0.1:${address.port}${path}`, [TERMINAL_PROTOCOL_V2], {
        headers: { Authorization: `Bearer ${config.token}` },
      });
      websocket.once("unexpected-response", (_request, response) => {
        response.resume();
        resolve(response.statusCode);
      });
      websocket.once("error", reject);
    });
  }
}

class V2Socket {
  readonly websocket: WebSocket;
  private readonly queue: V2Event[] = [];
  private resume: (() => void) | undefined;

  constructor(websocket: WebSocket) {
    this.websocket = websocket;
    websocket.on("message", (raw, isBinary) => {
      const buffer = Buffer.isBuffer(raw) ? raw : Buffer.concat(raw as Buffer[]);
      if (isBinary) {
        assert.equal(buffer[0], OUTPUT_FRAME_TYPE);
        this.queue.push({
          kind: "output",
          offset: Number(buffer.readBigUInt64BE(1)),
          data: buffer.subarray(OUTPUT_FRAME_HEADER_BYTES).toString("utf8"),
        });
      } else {
        this.queue.push({
          kind: "control",
          message: JSON.parse(buffer.toString()) as ServerTerminalMessage,
        });
      }
      this.resume?.();
      this.resume = undefined;
    });
  }

  async nextControl(): Promise<ServerTerminalMessage> {
    const event = await this.nextEvent();
    assert.equal(event.kind, "control");
    if (event.kind !== "control") throw new Error("unreachable");
    return event.message;
  }

  async nextOutput(): Promise<{ offset: number; data: string }> {
    const event = await this.nextEvent();
    assert.equal(event.kind, "output");
    if (event.kind !== "output") throw new Error("unreachable");
    return { offset: event.offset, data: event.data };
  }

  async close(): Promise<void> {
    if (this.websocket.readyState === WebSocket.CLOSED) return;
    const closed = once(this.websocket, "close");
    if (this.websocket.readyState === WebSocket.OPEN) this.websocket.close();
    await closed;
  }

  private async nextEvent(): Promise<V2Event> {
    const deadline = Date.now() + 2_000;
    while (this.queue.length === 0) {
      if (Date.now() > deadline) throw new Error("Timed out waiting for a terminal event.");
      await new Promise<void>((resolve) => {
        this.resume = resolve;
        setTimeout(resolve, 50);
      });
    }
    const event = this.queue.shift();
    if (!event) throw new Error("Terminal event queue is empty.");
    return event;
  }
}

function close(server: Server): Promise<void> {
  return new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}

async function waitUntil(condition: () => boolean): Promise<void> {
  const deadline = Date.now() + 1_000;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error("Timed out waiting for terminal state.");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}
