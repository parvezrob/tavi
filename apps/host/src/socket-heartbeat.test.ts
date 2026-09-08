import assert from "node:assert/strict";
import { EventEmitter, once } from "node:events";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import test from "node:test";
import WebSocket from "ws";
import { AttentionOverlay, AttentiveAgentEvents } from "./attention.js";
import { createChaos } from "./chaos.js";
import { EVENTS_PROTOCOL, MAX_TERMINAL_FRAME_BYTES } from "./protocol.js";
import { EVENTS_PING_INTERVAL_MILLISECONDS, keepAlive } from "./socket-heartbeat.js";
import { ChaosTestClock } from "./testing/chaos-clock.js";
import {
  close,
  harnessConfig as config,
  FakeAgentEvents,
  TerminalHarness,
  waitUntil,
} from "./testing/terminal-harness.js";

// The events socket's heartbeat (#111) and the two idle costs #68 named, over
// the real host on loopback with a real `ws` client. Every 15 s window is a
// `clock.advance` — the suite must never wait out a 45 s terminate — and the
// two seams a wall clock cannot reach (a ping whose send completion never
// returns, a close while one is pending) are driven against `keepAlive`
// directly.

const INTERVAL = EVENTS_PING_INTERVAL_MILLISECONDS;
const SETTLE_MS = 150;

function settle(): Promise<unknown> {
  return new Promise((resolve) => setTimeout(resolve, SETTLE_MS));
}

// A phone that answers no ping by itself, so the host's own count is what the
// test measures.
function openEvents(server: Server, options: WebSocket.ClientOptions = {}): WebSocket {
  const port = (server.address() as AddressInfo).port;
  return new WebSocket(`ws://127.0.0.1:${port}/api/events`, [EVENTS_PROTOCOL], {
    autoPong: false,
    headers: { Authorization: `Bearer ${config.token}` },
    ...options,
  });
}

async function blackholeEvents(server: Server, ms: number): Promise<void> {
  const port = (server.address() as AddressInfo).port;
  const answer = await fetch(`http://127.0.0.1:${port}/api/chaos/fault`, {
    method: "POST",
    headers: { Authorization: `Bearer ${config.token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ kind: "blackhole", socket: "events", ms }),
  });
  assert.equal(answer.status, 201);
}

function chaosHarness(clock: ChaosTestClock): TerminalHarness {
  const harness = new TerminalHarness();
  harness.chaos = createChaos(clock);
  return harness;
}

class FakeSocket extends EventEmitter {
  readonly OPEN = 1;
  readyState = 1;
  pings = 0;
  terminates = 0;
  // The completion of the last ping, so a test can leave it pending or run it late.
  lastCompletion: (() => void) | undefined;

  terminate(): void {
    this.terminates += 1;
    this.readyState = 3;
  }

  asWebSocket(): WebSocket {
    return this as unknown as WebSocket;
  }
}

test("the events socket is pinged every 15 s and terminated after two unanswered pings", {
  timeout: 15_000,
}, async () => {
  const clock = new ChaosTestClock();
  const harness = chaosHarness(clock);
  const server = await harness.startServer();

  try {
    const websocket = openEvents(server);
    let pings = 0;
    websocket.on("ping", () => {
      pings += 1;
    });
    await once(websocket, "open");
    const closed = once(websocket, "close");

    clock.advance(INTERVAL);
    await waitUntil(() => pings === 1);

    // 30 s: the first ping is still unanswered, so this one is a miss — and
    // the socket is still up, because one missed ping is a slow network.
    clock.advance(INTERVAL);
    await waitUntil(() => pings === 2);
    await settle();
    assert.equal(websocket.readyState, WebSocket.OPEN);

    // 45 s: the second miss. A terminate sends no close frame at all, which is
    // what 1006 means on the client.
    clock.advance(INTERVAL);
    const [code] = await closed;
    assert.equal(code, 1006);
    assert.equal(pings, 2);
  } finally {
    await close(server);
  }
});

test("a pong resets the count, and one arriving at 44 s keeps the socket", { timeout: 15_000 }, async () => {
  const clock = new ChaosTestClock();
  const harness = chaosHarness(clock);
  const server = await harness.startServer();

  try {
    const websocket = openEvents(server);
    let pings = 0;
    websocket.on("ping", () => {
      pings += 1;
    });
    await once(websocket, "open");

    clock.advance(INTERVAL);
    await waitUntil(() => pings === 1);
    clock.advance(INTERVAL);
    await waitUntil(() => pings === 2);

    // 44 s — one second before the terminate would land. The host has to see
    // it, so the assertion below waits for the frame rather than the clock.
    websocket.pong();
    await settle();

    clock.advance(INTERVAL);
    await waitUntil(() => pings === 3);
    await settle();
    assert.equal(websocket.readyState, WebSocket.OPEN, "a pong at 44 s must have cleared both the miss and the count");

    // And the count really is back to zero: it takes two more silent intervals
    // to terminate, not one.
    clock.advance(INTERVAL);
    await waitUntil(() => pings === 4);
    await settle();
    assert.equal(websocket.readyState, WebSocket.OPEN);

    const closed = once(websocket, "close");
    clock.advance(INTERVAL);
    assert.equal((await closed)[0], 1006);
  } finally {
    await close(server);
  }
});

test("a blackholed events socket is neither pinged nor counted, and counting resumes after the window", {
  timeout: 15_000,
}, async () => {
  const clock = new ChaosTestClock();
  const harness = chaosHarness(clock);
  const server = await harness.startServer();

  try {
    const websocket = openEvents(server);
    let pings = 0;
    websocket.on("ping", () => {
      pings += 1;
    });
    await once(websocket, "open");

    // Deliberately not a multiple of the interval: the window has to end
    // strictly between two ticks for "resumes after the window" to mean it.
    await blackholeEvents(server, 2 * INTERVAL + 1_000);

    // Two whole intervals inside the window: a socket the host itself gagged
    // owes it no pong, so nothing is sent and nothing is counted.
    clock.advance(INTERVAL);
    await settle();
    assert.equal(pings, 0);
    clock.advance(INTERVAL);
    await settle();
    assert.equal(pings, 0);
    assert.equal(websocket.readyState, WebSocket.OPEN);

    // The window has ended; the count starts from zero, so it takes the full
    // ping, miss, terminate sequence again.
    const closed = once(websocket, "close");
    clock.advance(INTERVAL);
    await waitUntil(() => pings === 1);
    clock.advance(INTERVAL);
    await waitUntil(() => pings === 2);
    await settle();
    assert.equal(websocket.readyState, WebSocket.OPEN);
    clock.advance(INTERVAL);
    assert.equal((await closed)[0], 1006);
  } finally {
    await close(server);
  }
});

test("a ping whose send completion never returns still misses on the next tick and terminates on schedule", () => {
  const clock = new ChaosTestClock();
  const socket = new FakeSocket();
  keepAlive(socket.asWebSocket(), {
    clock,
    // The completion is captured and never called: a phone whose TCP window is
    // full leaves the host's write pending indefinitely.
    send: (_websocket, done) => {
      socket.pings += 1;
      socket.lastCompletion = done;
    },
  });

  clock.advance(INTERVAL);
  assert.equal(socket.pings, 1);
  clock.advance(INTERVAL);
  assert.equal(socket.pings, 2);
  assert.equal(socket.terminates, 0);
  clock.advance(INTERVAL);
  assert.equal(socket.terminates, 1);
  assert.equal(socket.pings, 2, "the terminating tick has nothing left to ask");
});

test("a close mid-interval leaves no timer: a completion still pending is harmless and no ping follows", () => {
  const clock = new ChaosTestClock();
  const socket = new FakeSocket();
  keepAlive(socket.asWebSocket(), {
    clock,
    send: (_websocket, done) => {
      socket.pings += 1;
      socket.lastCompletion = done;
    },
  });

  clock.advance(INTERVAL);
  assert.equal(socket.pings, 1);
  socket.readyState = 3;
  socket.emit("close");
  socket.lastCompletion?.();

  clock.advance(10 * INTERVAL);
  assert.equal(socket.pings, 1, "a closed socket is never pinged again");
  assert.equal(socket.terminates, 0);
});

test("ws hands the ping completion the host relies on a real post-close error, and throws nothing", async () => {
  const harness = new TerminalHarness();
  const server = await harness.startServer();

  try {
    const websocket = openEvents(server, { autoPong: true });
    await once(websocket, "open");
    websocket.close();
    await once(websocket, "close");

    // The exact call `keepAlive`'s default send makes. ws reports the failure
    // through the completion rather than throwing, which is the whole reason
    // the heartbeat can hand it a callback that does nothing.
    const failed = new Promise<Error | undefined>((resolve) => {
      assert.doesNotThrow(() => websocket.ping(undefined, undefined, resolve));
    });
    assert.ok(await failed, "a ping after close must report through the completion");
  } finally {
    await close(server);
  }
});

test("a ping already outstanding when a blackhole opens is not a miss once the window ends", {
  timeout: 15_000,
}, async () => {
  const clock = new ChaosTestClock();
  const harness = chaosHarness(clock);
  const server = await harness.startServer();

  try {
    const websocket = openEvents(server);
    let pings = 0;
    websocket.on("ping", () => {
      pings += 1;
    });
    await once(websocket, "open");

    // One unanswered ping on the wire, and *then* the host gags the socket.
    clock.advance(INTERVAL);
    await waitUntil(() => pings === 1);
    await blackholeEvents(server, INTERVAL + 1_000);
    clock.advance(INTERVAL);
    await settle();
    assert.equal(pings, 1);

    // The window is over. If that first ping still counted, the next two ticks
    // would be miss one and miss two and this socket would be gone at the
    // second — it must survive to the third.
    clock.advance(INTERVAL);
    await waitUntil(() => pings === 2);
    const closed = once(websocket, "close");
    clock.advance(INTERVAL);
    await waitUntil(() => pings === 3);
    await settle();
    assert.equal(websocket.readyState, WebSocket.OPEN, "the pre-blackhole ping must not have counted");
    clock.advance(INTERVAL);
    assert.equal((await closed)[0], 1006);
  } finally {
    await close(server);
  }
});

test("a miss counted before a blackhole still counts after it: one more is enough to terminate", {
  timeout: 15_000,
}, async () => {
  const clock = new ChaosTestClock();
  const harness = chaosHarness(clock);
  const server = await harness.startServer();

  try {
    const websocket = openEvents(server);
    let pings = 0;
    websocket.on("ping", () => {
      pings += 1;
    });
    await once(websocket, "open");

    // Ping, then a real miss: this socket is already one away from gone.
    clock.advance(INTERVAL);
    await waitUntil(() => pings === 1);
    clock.advance(INTERVAL);
    await waitUntil(() => pings === 2);

    // A fault on alternate ticks is what the soak does. If a gated tick wiped
    // the miss as well as the outstanding ping, every other tick would reset
    // the count and a dead socket would never be terminated at all.
    await blackholeEvents(server, INTERVAL + 1_000);
    clock.advance(INTERVAL);
    await settle();
    assert.equal(pings, 2, "nothing is sent while the gate is shut");

    const closed = once(websocket, "close");
    clock.advance(INTERVAL);
    await waitUntil(() => pings === 3);
    await settle();
    assert.equal(websocket.readyState, WebSocket.OPEN, "the forgiven ping is only the one the peer never saw");
    clock.advance(INTERVAL);
    assert.equal((await closed)[0], 1006, "the miss from before the window was still on the count");
  } finally {
    await close(server);
  }
});

test("a 65 KiB text frame from a phone closes the events socket with 1009", async () => {
  const harness = new TerminalHarness();
  const server = await harness.startServer();

  try {
    const websocket = openEvents(server, { autoPong: true });
    await once(websocket, "open");
    const closed = once(websocket, "close");
    websocket.send("x".repeat(MAX_TERMINAL_FRAME_BYTES + 1_024));
    const [code] = await closed;
    assert.equal(code, 1009);
  } finally {
    await close(server);
  }
});

// Counts the `{"type":"agents",…}` envelopes built while `act` runs. The
// production chain has two publishers — the feed serializes its own pre-merge
// text as its change detector, the attention wrapper serializes the merged
// one — and what #68 finding 2 asks is that neither number moves with the
// number of phones.
async function countEnvelopes(act: () => Promise<void>): Promise<number> {
  const original = JSON.stringify;
  let envelopes = 0;
  JSON.stringify = ((...args: Parameters<typeof JSON.stringify>) => {
    const text = original(...args);
    if (typeof text === "string" && text.startsWith('{"type":"agents"')) envelopes += 1;
    return text;
  }) as typeof JSON.stringify;
  try {
    await act();
  } finally {
    JSON.stringify = original;
  }
  return envelopes;
}

test("a snapshot is serialized once per publisher, never once per phone, and every phone gets the same bytes", async () => {
  const inner = new FakeAgentEvents();
  const harness = new TerminalHarness();
  harness.agentEvents = new AttentiveAgentEvents(inner, new AttentionOverlay());
  const server = await harness.startServer();
  const snapshot = (id: string) => ({
    available: true,
    agents: [
      {
        id,
        agent: "claude",
        status: "idle",
        cwd: "/work",
        title: "",
        workspaceId: "wB",
        tabId: "wB:t1",
        focused: false,
        revision: 1,
        authority: "herdr",
      },
    ],
  });

  try {
    const first: string[] = [];
    const second: string[] = [];
    const sockets: WebSocket[] = [];
    for (const [websocket, sink] of [
      [openEvents(server, { autoPong: true }), first],
      [openEvents(server, { autoPong: true }), second],
    ] as Array<[WebSocket, string[]]>) {
      websocket.on("message", (raw) => sink.push(raw.toString()));
      sockets.push(websocket);
      await once(websocket, "open");
    }
    await waitUntil(() => first.length === 1 && second.length === 1);

    const withTwo = await countEnvelopes(async () => {
      inner.publish(snapshot("wB:p1"));
      await waitUntil(() => first.length === 2 && second.length === 2);
    });
    assert.equal(
      withTwo,
      2,
      "one envelope from the feed and one from the merge, and two phones made it neither 3 nor 4",
    );
    assert.equal(first[1], second[1], "both phones are handed the very same text");
    assert.match(first[1] ?? "", /^\{"type":"agents","available":true,/);

    // The number that must not move: drop a phone and publish again.
    sockets[1]?.close();
    await once(sockets[1] as WebSocket, "close");
    const withOne = await countEnvelopes(async () => {
      inner.publish(snapshot("wB:p2"));
      await waitUntil(() => first.length === 3);
    });
    assert.equal(withOne, withTwo, "the envelope count follows the publishers, not the sockets");
  } finally {
    await close(server);
  }
});

test("a retained snapshot still replays as one frame when the blackhole ends", async () => {
  const clock = new ChaosTestClock();
  const harness = chaosHarness(clock);
  const inner = new FakeAgentEvents();
  harness.agentEvents = new AttentiveAgentEvents(inner, new AttentionOverlay());
  const server = await harness.startServer();

  try {
    const frames: string[] = [];
    const websocket = openEvents(server, { autoPong: true });
    websocket.on("message", (raw) => frames.push(raw.toString()));
    await once(websocket, "open");
    await waitUntil(() => frames.length === 1);

    await blackholeEvents(server, INTERVAL);
    inner.publish({ available: true, agents: [] });
    inner.publish({ available: false, reason: "Herdr is unavailable.", agents: [] });
    await settle();
    assert.equal(frames.length, 1);

    clock.advance(INTERVAL);
    await waitUntil(() => frames.length === 2);
    assert.equal(
      frames[1],
      JSON.stringify({ type: "agents", available: false, reason: "Herdr is unavailable.", agents: [] }),
    );
    websocket.close();
    await once(websocket, "close");
  } finally {
    await close(server);
  }
});
