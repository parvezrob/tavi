import assert from "node:assert/strict";
import { once } from "node:events";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import test from "node:test";
import type { IPty } from "node-pty";
import WebSocket from "ws";
import type { HostConfig } from "./config.js";
import { TERMINAL_PROTOCOL } from "./protocol.js";
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
