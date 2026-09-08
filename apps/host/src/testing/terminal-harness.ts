import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtempSync } from "node:fs";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import type { IPty } from "node-pty";
import WebSocket from "ws";
import { AgentKindDetector } from "../agent-kinds.js";
import { agentsFrame, type AgentEventSource, type AgentsListener, type HerdrAgentsSnapshot } from "../herdr-events.js";
import type { HerdrAgentSource } from "../herdr-types.js";
import { EVENTS_PROTOCOL, OUTPUT_FRAME_HEADER_BYTES, OUTPUT_FRAME_TYPE, TERMINAL_PROTOCOL_V2 } from "../protocol.js";
import { ProjectHistory } from "../projects.js";
import { createTaviServer, type TaviServerOptions } from "../server.js";
import type { HerdrAgentInfo, ServerTerminalMessage } from "../types.js";
import { testConfig } from "./config.js";

// The real host on loopback with a fake pty behind it: what `server.v2.test.ts`
// has driven the v2 bridge with since #98, moved here in #111 so the chaos
// suite drives the same one instead of growing a second.

export const harnessConfig = testConfig({
  port: 0,
  herdrSocket: path.join(tmpdir(), "tavi-v2-test-herdr.sock"),
  roots: [tmpdir()],
  stateDir: tmpdir(),
  machineName: "Test",
});

type V2Event = { kind: "control"; message: ServerTerminalMessage } | { kind: "output"; offset: number; data: string };

export class FakeTerminal {
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

// The bridge's backend when a test does not bring its own herdr: one pane,
// "fixture", attached through the herdr CLI.
function fixtureHerdr(): HerdrAgentSource {
  const agent = {
    id: "fixture",
    agent: "claude",
    status: "idle" as const,
    cwd: "/work",
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
    closeTab: async () => ({ closed: true as const }),
    renameTab: async (_tabId: string, label: string) => ({ renamed: true as const, label }),
    findAgent: async (paneId: string) =>
      paneId === agent.id ? { available: true as const, agent } : { available: true as const },
    attachCommand: (paneId: string) => ({ bin: "herdr", args: ["agent", "attach", paneId] }),
    readAgent: async () => ({ available: true as const, preview: "" }),
    readDialog: async () => ({ present: false as const }),
    decideAgent: async () => ({ decided: true as const, sent: "Enter" }),
    promptAgent: async () => ({ submitted: true as const }),
    createTab: async () => ({ created: true as const, paneId: "wB:p9", tabId: "wB:t9" }),
  };
}

// A published agent, with everything a test does not care about already
// filled in — so a suite says `{ id: "wB:p1" }` and still hands the host a
// real `HerdrAgentInfo`.
export function fakeAgent(overrides: Partial<HerdrAgentInfo> & { id: string }): HerdrAgentInfo {
  return {
    agent: "claude",
    status: "idle",
    cwd: "/work",
    title: "",
    workspaceId: "wB",
    tabId: "wB:t1",
    focused: false,
    revision: 1,
    authority: "herdr",
    ...overrides,
  };
}

// An events feed a test publishes into by hand. It builds the wire frame the
// way the real feed does, so a suite never re-states the envelope's shape.
export class FakeAgentEvents implements AgentEventSource {
  latest: HerdrAgentsSnapshot | undefined;
  private readonly listeners = new Set<AgentsListener>();

  start(): void {}
  stop(): void {}

  subscribe(listener: AgentsListener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  get subscriberCount(): number {
    return this.listeners.size;
  }

  publish(snapshot: {
    available: boolean;
    reason?: string;
    agents: Array<Partial<HerdrAgentInfo> & { id: string }>;
  }): void {
    const published: HerdrAgentsSnapshot = { ...snapshot, agents: snapshot.agents.map(fakeAgent) };
    this.latest = published;
    const frame = agentsFrame(published);
    for (const listener of [...this.listeners]) listener(published, frame);
  }
}

export class TerminalHarness {
  readonly terminals: FakeTerminal[] = [];
  agentEvents: TaviServerOptions["agentEvents"];
  chaos: TaviServerOptions["chaos"];
  devices: TaviServerOptions["devices"];
  herdr: TaviServerOptions["herdr"];
  authorizationRecheckMs: TaviServerOptions["authorizationRecheckMs"];
  // The bearer every client below presents; a paired phone's credential when a
  // test needs one that can be revoked, the host's own token otherwise.
  credential = harnessConfig.token;
  recordSpawn: ((bin: string, args: string[]) => void) | undefined;

  get spawnCount(): number {
    return this.terminals.length;
  }

  async startServer(): Promise<Server> {
    const server = await createTaviServer({
      config: harnessConfig,
      // Never the developer's real state directory: creating an agent
      // records the folder, and that must not leak between test runs.
      projects: new ProjectHistory(mkdtempSync(path.join(tmpdir(), "tavi-v2-state-"))),
      agentKinds: new AgentKindDetector({ shell: "/bin/sh", runShell: async () => "claude\n" }),
      herdr: this.herdr ?? fixtureHerdr(),
      ...(this.agentEvents ? { agentEvents: this.agentEvents } : {}),
      ...(this.chaos ? { chaos: this.chaos } : {}),
      ...(this.devices ? { devices: this.devices } : {}),
      ...(this.authorizationRecheckMs ? { authorizationRecheckMs: this.authorizationRecheckMs } : {}),
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

  async openSocket(server: Server, query = "", path = "/api/agents/fixture/terminal"): Promise<V2Socket> {
    const address = server.address() as AddressInfo;
    const suffix = query ? `?${query}` : "";
    const websocket = new WebSocket(`ws://127.0.0.1:${address.port}${path}${suffix}`, [TERMINAL_PROTOCOL_V2], {
      headers: { Authorization: `Bearer ${this.credential}` },
    });
    const socket = new V2Socket(websocket);
    await once(websocket, "open");
    assert.equal(websocket.protocol, TERMINAL_PROTOCOL_V2);
    return socket;
  }

  // An events-stream client. The sink is attached before the handshake
  // completes on purpose: the host's first snapshot can land in the same tick.
  async openEvents(server: Server, onFrame?: (frame: Record<string, unknown>) => void): Promise<WebSocket> {
    const address = server.address() as AddressInfo;
    const websocket = new WebSocket(`ws://127.0.0.1:${address.port}/api/events`, [EVENTS_PROTOCOL], {
      headers: { Authorization: `Bearer ${this.credential}` },
    });
    if (onFrame) websocket.on("message", (raw) => onFrame(JSON.parse(raw.toString()) as Record<string, unknown>));
    await once(websocket, "open");
    return websocket;
  }

  upgradeStatus(server: Server, path: string): Promise<number | undefined> {
    const address = server.address() as AddressInfo;
    return new Promise((resolve, reject) => {
      const websocket = new WebSocket(`ws://127.0.0.1:${address.port}${path}`, [TERMINAL_PROTOCOL_V2], {
        headers: { Authorization: `Bearer ${this.credential}` },
      });
      websocket.once("unexpected-response", (_request, response) => {
        response.resume();
        resolve(response.statusCode);
      });
      websocket.once("error", reject);
    });
  }
}

export class V2Socket {
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

  async nextControl(timeoutMs?: number): Promise<ServerTerminalMessage> {
    const event = await this.nextEvent(timeoutMs);
    assert.equal(event.kind, "control");
    if (event.kind !== "control") throw new Error("unreachable");
    return event.message;
  }

  async nextOutput(timeoutMs?: number): Promise<{ offset: number; data: string }> {
    const event = await this.nextEvent(timeoutMs);
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

  /** How many events are already queued, for asserting that none arrived. */
  get pending(): number {
    return this.queue.length;
  }

  private async nextEvent(timeoutMs = 2_000): Promise<V2Event> {
    const deadline = Date.now() + timeoutMs;
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

export async function closeOutcome(closed: Promise<unknown[]>): Promise<{ code: number; reason: string }> {
  const [code, reason] = await closed;
  return { code: code as number, reason: (reason as Buffer).toString() };
}

export function close(server: Server): Promise<void> {
  return new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}

export async function waitUntil(condition: () => boolean | Promise<boolean>, timeoutMs = 1_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!(await condition())) {
    if (Date.now() > deadline) throw new Error("Timed out waiting for terminal state.");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}
