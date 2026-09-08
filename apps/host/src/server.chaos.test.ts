import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtempSync } from "node:fs";
import type { Server } from "node:http";
import { type AddressInfo, connect } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import type { Duplex } from "node:stream";
import test from "node:test";
import WebSocket from "ws";
import { createChaos } from "./chaos.js";
import { DeviceRegistry } from "./pairing.js";
import { EVENTS_PROTOCOL } from "./protocol.js";
import { ChaosTestClock } from "./testing/chaos-clock.js";
import {
  close,
  closeOutcome,
  harnessConfig as config,
  FakeAgentEvents,
  TerminalHarness,
  waitUntil,
} from "./testing/terminal-harness.js";

// Chaos mode over the real host on loopback (#111). Every fault is requested
// the way the soak requests it — through the routes — and every window it
// opens is closed by moving `ChaosTestClock`, never by sleeping through it: the
// route's own minimum is 1 s and the soak uses 30 s and 70 s ones.
//
// The sockets are real, so "nothing arrived" still needs a moment for a frame
// to fail to cross loopback; SETTLE_MS is that, not a window.

const SETTLE_MS = 150;

type ChaosAnswer = { status: number; body: Record<string, unknown> };

async function chaosRequest(
  server: Server,
  route: string,
  init?: RequestInit & { credential?: string | undefined },
): Promise<ChaosAnswer> {
  const port = (server.address() as AddressInfo).port;
  const credential = init?.credential ?? config.token;
  const response = await fetch(`http://127.0.0.1:${port}/api/chaos/${route}`, {
    ...init,
    headers: {
      ...(credential === "" ? {} : { Authorization: `Bearer ${credential}` }),
      "Content-Type": "application/json",
    },
  });
  return { status: response.status, body: (await response.json()) as Record<string, unknown> };
}

function postFault(server: Server, body: unknown): Promise<ChaosAnswer> {
  return chaosRequest(server, "fault", { method: "POST", body: JSON.stringify(body) });
}

async function faultEvents(server: Server): Promise<Array<Record<string, unknown>>> {
  const answer = await chaosRequest(server, "events");
  assert.equal(answer.status, 200);
  return answer.body.events as Array<Record<string, unknown>>;
}

function chaosHarness(clock: ChaosTestClock = new ChaosTestClock()): TerminalHarness {
  const harness = new TerminalHarness();
  harness.chaos = createChaos(clock);
  return harness;
}

function settle(): Promise<unknown> {
  return new Promise((resolve) => setTimeout(resolve, SETTLE_MS));
}

test("the chaos routes do not exist on a host without TAVI_CHAOS", async () => {
  const harness = new TerminalHarness();
  const server = await harness.startServer();

  try {
    assert.equal((await postFault(server, { kind: "terminate", socket: "events" })).status, 404);
    assert.equal((await chaosRequest(server, "events")).status, 404);
    assert.equal((await chaosRequest(server, "attachments")).status, 404);
  } finally {
    await close(server);
  }
});

test("a fault body the runner got wrong is a 400, and a fault with no target is a 404", async () => {
  const clock = new ChaosTestClock();
  const harness = chaosHarness(clock);
  const server = await harness.startServer();

  try {
    for (const body of [
      {},
      { kind: "sleep", socket: "events" },
      { kind: "terminate", socket: "wire" },
      { kind: "terminate", socket: "terminal" },
      { kind: "blackhole", socket: "events" },
      { kind: "hostPause" },
      { kind: "blackhole", socket: "events", ms: 10 },
      { kind: "blackhole", socket: "events", ms: 600_000 },
      { kind: "closeMidOutput", socket: "events", code: 1000 },
      { kind: "terminate", socket: "events", thenSlowReadyMs: 500 },
    ]) {
      const answer = await postFault(server, body);
      assert.equal(answer.status, 400, `expected 400 for ${JSON.stringify(body)}`);
      assert.equal(typeof answer.body.error, "string");
    }

    // Nothing is attached and no phone holds the stream, so neither fault has
    // anywhere to land — the soak reads that as its own failure, not the host's.
    assert.deepEqual(await postFault(server, { kind: "terminate", socket: "events" }), {
      status: 404,
      body: { error: "No socket to fault." },
    });
    assert.deepEqual(await postFault(server, { kind: "terminate", socket: "terminal", paneId: "fixture" }), {
      status: 404,
      body: { error: "No socket to fault." },
    });
    assert.deepEqual(await faultEvents(server), []);

    // The soak sends `hostPause` with no socket at all — the contract ignores
    // the field for it, so the body must be accepted as it stands.
    const bare = await postFault(server, { kind: "hostPause", ms: 1_000 });
    assert.equal(bare.status, 201);
    clock.advance(1_000);
    assert.equal((await faultEvents(server))[0]?.kind, "hostPause");
  } finally {
    await close(server);
  }
});

test("terminate drops the terminal with no close frame at all", async () => {
  const harness = chaosHarness();
  const server = await harness.startServer();

  try {
    const socket = await harness.openSocket(server);
    assert.equal((await socket.nextControl()).type, "ready");

    const closed = once(socket.websocket, "close");
    const answer = await postFault(server, { kind: "terminate", socket: "terminal", paneId: "fixture" });
    assert.equal(answer.status, 201);
    assert.equal(typeof answer.body.id, "string");
    assert.ok((answer.body.at as number) > 0);

    // 1006 is what a client reports when the connection ended without one.
    const [code] = await closed;
    assert.equal(code, 1006);

    const events = await faultEvents(server);
    assert.equal(events.length, 1);
    assert.equal(events[0]?.id, answer.body.id);
    assert.equal(events[0]?.kind, "terminate");
    assert.equal(events[0]?.paneId, "fixture");
  } finally {
    await close(server);
  }
});

test("closeMidOutput arrives as an orderly close with the code the runner asked for", async () => {
  const harness = chaosHarness();
  const server = await harness.startServer();

  try {
    for (const code of [1011, 1001]) {
      const socket = await harness.openSocket(server);
      assert.equal((await socket.nextControl()).type, "ready");
      const closed = once(socket.websocket, "close");
      const answer = await postFault(server, { kind: "closeMidOutput", socket: "terminal", paneId: "fixture", code });
      assert.equal(answer.status, 201);
      assert.deepEqual(await closeOutcome(closed), { code, reason: "chaos" });
    }
  } finally {
    await close(server);
  }
});

test("a blackholed events socket keeps TCP up, answers no ping, and sends one retained snapshot", async () => {
  const clock = new ChaosTestClock();
  const harness = chaosHarness(clock);
  const agentEvents = new FakeAgentEvents();
  harness.agentEvents = agentEvents;
  const server = await harness.startServer();

  try {
    const frames: Array<Record<string, unknown>> = [];
    let pongs = 0;
    const websocket = await harness.openEvents(server, (frame) => frames.push(frame));
    websocket.on("pong", () => {
      pongs += 1;
    });
    await waitUntil(() => frames.length === 1);

    // 30 s: the window the soak's terminal rotation uses.
    assert.equal((await postFault(server, { kind: "blackhole", socket: "events", ms: 30_000 })).status, 201);
    websocket.ping();
    agentEvents.publish({ available: true, agents: [{ id: "wB:p1" }] });
    agentEvents.publish({ available: true, agents: [{ id: "wB:p1" }, { id: "wB:p2" }] });
    await settle();

    // TCP is up — the phone's socket never errors — but nothing comes back.
    assert.equal(websocket.readyState, WebSocket.OPEN);
    assert.equal(frames.length, 1);
    assert.equal(pongs, 0);

    // One snapshot carries the whole list, so only the latest skipped one is
    // worth replaying; the older one would paint state that is already gone.
    clock.advance(30_000);
    await waitUntil(() => frames.length === 2 && pongs === 1, 3_000);
    assert.equal((frames[1]?.agents as unknown[] | undefined)?.length, 2);
    await settle();
    assert.equal(frames.length, 2);
    websocket.close();
    await once(websocket, "close");
  } finally {
    await close(server);
  }
});

test("a blackholed terminal holds its flush and loses no input the phone sent", async () => {
  const clock = new ChaosTestClock();
  const harness = chaosHarness(clock);
  const server = await harness.startServer();

  try {
    const socket = await harness.openSocket(server);
    assert.equal((await socket.nextControl()).type, "ready");
    socket.websocket.send(JSON.stringify({ type: "input", data: "before\r" }));
    await waitUntil(() => harness.terminals[0]?.writes.length === 1);

    assert.equal(
      (await postFault(server, { kind: "blackhole", socket: "terminal", paneId: "fixture", ms: 30_000 })).status,
      201,
    );
    socket.websocket.send(JSON.stringify({ type: "input", data: "during\r" }));
    socket.websocket.send(JSON.stringify({ type: "ping", id: "beat" }));
    harness.terminals[0]?.emitData("held output");
    await settle();
    assert.equal(socket.pending, 0);
    assert.equal(socket.websocket.readyState, WebSocket.OPEN);

    // The cursor waited: the output arrives once, at the offset it always had.
    clock.advance(30_000);
    const output = await socket.nextOutput(3_000);
    assert.deepEqual(output, { offset: 0, data: "held output" });
    assert.deepEqual(await socket.nextControl(), { type: "pong", id: "beat" });
    assert.deepEqual(harness.terminals[0]?.writes, ["before\r", "during\r"]);
    await socket.close();
  } finally {
    await close(server);
  }
});

// Bounded on purpose: without `revoke` this test would still pass, 30 s later,
// on ws's close timeout — the deadline is what makes it a test.
test("revoking a phone inside a blackhole drops its handling at once, not on ws's close timeout", {
  timeout: 5_000,
}, async () => {
  const devices = new DeviceRegistry(mkdtempSync(path.join(tmpdir(), "tavi-chaos-revoke-")), undefined, () => {});
  const { device, credential } = devices.add("phone");
  const harness = chaosHarness();
  harness.devices = devices;
  harness.authorizationRecheckMs = 20;
  harness.credential = credential;
  const server = await harness.startServer();

  try {
    const socket = await harness.openSocket(server);
    assert.equal((await socket.nextControl()).type, "ready");
    // Long enough that a socket left to ws's own 30 s close timeout would still
    // be paused when this test ends.
    assert.equal(
      (await postFault(server, { kind: "blackhole", socket: "terminal", paneId: "fixture", ms: 120_000 })).status,
      201,
    );

    const closed = once(socket.websocket, "close");
    devices.revoke(device.id);
    assert.deepEqual(await closeOutcome(closed), { code: 4401, reason: "credential revoked" });

    // The invariant that costs something: the pty is let go now — not in 30 s —
    // so the pane is free for the next phone and no queued frame reaches the
    // bridge on the way out. Without `chaos.revoke` this row has no
    // `releasedAt` until ws's close timeout fires.
    await waitUntil(async () => (await rows(server))[0]?.releasedAt !== undefined, 1_000);
  } finally {
    await close(server);
  }
});

test("a terminal that closes while blackholed discards the window and never resumes its traffic", async () => {
  const clock = new ChaosTestClock();
  const harness = chaosHarness(clock);
  const server = await harness.startServer();

  try {
    const first = await harness.openSocket(server);
    const ready = await first.nextControl();
    assert.equal(ready.type, "ready");
    const stream = ready.type === "ready" ? ready.stream : "";

    assert.equal(
      (await postFault(server, { kind: "blackhole", socket: "terminal", paneId: "fixture", ms: 30_000 })).status,
      201,
    );
    harness.terminals[0]?.emitData("never shown");
    const closed = once(first.websocket, "close");
    const second = await harness.openSocket(server, `stream=${stream}&resume=0`);
    assert.equal((await second.nextControl()).type, "ready");

    // The superseded frame and its close were held by the gate; when the
    // window ends the close goes out and the held output does not.
    clock.advance(30_000);
    await closed;
    assert.equal(first.pending, 0);
    assert.equal((await second.nextOutput()).data, "never shown");
    await second.close();
  } finally {
    await close(server);
  }
});

test("thenSlowReadyMs holds ready and every byte behind it, then names the attach that took it", async () => {
  const clock = new ChaosTestClock();
  const harness = chaosHarness(clock);
  const server = await harness.startServer();

  try {
    const first = await harness.openSocket(server);
    const ready = await first.nextControl();
    const stream = ready.type === "ready" ? ready.stream : "";
    const closed = once(first.websocket, "close");
    // 6 s is the soak's own arming.
    assert.equal(
      (
        await postFault(server, {
          kind: "terminate",
          socket: "terminal",
          paneId: "fixture",
          thenSlowReadyMs: 6_000,
        })
      ).status,
      201,
    );
    await closed;
    harness.terminals[0]?.emitData("while away");

    const second = await harness.openSocket(server, `stream=${stream}&resume=0`);
    // The pane keeps talking during the hold — the soak's fixture prints every
    // 0.2 s — and none of it may precede `ready` on the wire.
    harness.terminals[0]?.emitData(" and during");
    await settle();
    assert.equal(second.pending, 0);

    clock.advance(6_000);
    const held = await second.nextControl(3_000);
    assert.equal(held.type, "ready");
    assert.equal(held.type === "ready" ? held.resumed : false, true);
    assert.equal((await second.nextOutput()).data, "while away and during");

    const events = await faultEvents(server);
    assert.equal(events[0]?.thenSlowReadyMs, 6_000);
    assert.ok((events[0]?.consumedByAttachAt as number) >= (events[0]?.at as number));
    await second.close();
  } finally {
    await close(server);
  }
});

test("a blackhole overlapping a slowReady hold still puts ready first when both end", async () => {
  const clock = new ChaosTestClock();
  const harness = chaosHarness(clock);
  const server = await harness.startServer();

  try {
    const first = await harness.openSocket(server);
    const ready = await first.nextControl();
    const stream = ready.type === "ready" ? ready.stream : "";
    const closed = once(first.websocket, "close");
    await postFault(server, {
      kind: "terminate",
      socket: "terminal",
      paneId: "fixture",
      thenSlowReadyMs: 6_000,
    });
    await closed;

    const second = await harness.openSocket(server, `stream=${stream}&resume=0`);
    clock.advance(2_000);
    assert.equal(
      (await postFault(server, { kind: "blackhole", socket: "terminal", paneId: "fixture", ms: 30_000 })).status,
      201,
    );
    harness.terminals[0]?.emitData("under both");

    // The hold expires inside the blackhole: `ready` cannot go out here, and
    // spending it on a closed gate would leave the phone reading output frames
    // for a stream it was never told about.
    clock.advance(4_500);
    await settle();
    assert.equal(second.pending, 0);

    clock.advance(30_000);
    const announced = await second.nextControl(3_000);
    assert.equal(announced.type, "ready");
    assert.deepEqual(await second.nextOutput(), { offset: 0, data: "under both" });
    await second.close();
  } finally {
    await close(server);
  }
});

test("a supersession during a slowReady hold cancels it and the loser still hears why", async () => {
  const harness = chaosHarness();
  const server = await harness.startServer();

  try {
    const first = await harness.openSocket(server);
    const ready = await first.nextControl();
    const stream = ready.type === "ready" ? ready.stream : "";
    const closed = once(first.websocket, "close");
    await postFault(server, {
      kind: "closeMidOutput",
      socket: "terminal",
      paneId: "fixture",
      code: 1001,
      thenSlowReadyMs: 30_000,
    });
    await closed;

    const held = await harness.openSocket(server, `stream=${stream}&resume=0`);
    await settle();
    assert.equal(held.pending, 0);

    const heldClosed = once(held.websocket, "close");
    const winner = await harness.openSocket(server, `stream=${stream}&resume=0`);
    assert.equal((await winner.nextControl()).type, "ready");
    assert.deepEqual(await held.nextControl(), {
      type: "error",
      message: "Another connection took over this terminal.",
      code: "superseded",
    });
    assert.deepEqual(await closeOutcome(heldClosed), { code: 1000, reason: "superseded" });
    await winner.close();
  } finally {
    await close(server);
  }
});

test("hostPause withholds every answer for the window, then the host answers again", async () => {
  const clock = new ChaosTestClock();
  const harness = chaosHarness(clock);
  const server = await harness.startServer();
  // A withheld upgrade leaves the host holding a socket nothing tracks any
  // more, so `server.close()` alone never finishes for it — the same reason
  // the fault leaves those sockets to the client's own timeout.
  const abandoned: Duplex[] = [];
  server.on("upgrade", (_request, socket) => abandoned.push(socket));
  const port = (server.address() as AddressInfo).port;

  try {
    assert.equal((await postFault(server, { kind: "hostPause", ms: 30_000 })).status, 201);

    // The client gives up; the host never answered and never will inside the
    // window, so the deadline here is the phone's, not the fault's.
    await assert.rejects(fetch(`http://127.0.0.1:${port}/api/health`, { signal: AbortSignal.timeout(SETTLE_MS) }));

    let answered = "";
    const raw = connect(port, "127.0.0.1", () => raw.write(eventsHandshake(port)));
    raw.on("data", (chunk: Buffer) => {
      answered += chunk.toString();
    });
    raw.on("error", () => undefined);
    await settle();
    assert.equal(answered, "");
    raw.destroy();

    clock.advance(30_000);
    const health = await fetch(`http://127.0.0.1:${port}/api/health`, { signal: AbortSignal.timeout(2_000) });
    assert.equal(health.status, 200);
  } finally {
    for (const socket of abandoned) socket.destroy();
    await close(server);
  }
});

test("a fault reaches only the socket it names", async () => {
  const harness = chaosHarness();
  const agentEvents = new FakeAgentEvents();
  harness.agentEvents = agentEvents;
  const server = await harness.startServer();

  try {
    const frames: unknown[] = [];
    const events = await harness.openEvents(server, (frame) => frames.push(frame));
    await waitUntil(() => frames.length === 1);
    const terminal = await harness.openSocket(server);
    assert.equal((await terminal.nextControl()).type, "ready");

    const terminalClosed = once(terminal.websocket, "close");
    await postFault(server, { kind: "terminate", socket: "terminal", paneId: "fixture" });
    await terminalClosed;
    agentEvents.publish({ available: true, agents: [] });
    await waitUntil(() => frames.length === 2);
    assert.equal(events.readyState, WebSocket.OPEN);

    const second = await harness.openSocket(server);
    assert.equal((await second.nextControl()).type, "ready");
    const eventsClosed = once(events, "close");
    await postFault(server, { kind: "terminate", socket: "events" });
    await eventsClosed;
    harness.terminals.at(-1)?.emitData("still mine");
    assert.equal((await second.nextOutput()).data, "still mine");
    await second.close();
  } finally {
    await close(server);
  }
});

test("the attachments view counts what the soak checks its offsets against", async () => {
  const harness = chaosHarness();
  const server = await harness.startServer();

  try {
    const first = await harness.openSocket(server);
    const ready = await first.nextControl();
    const stream = ready.type === "ready" ? ready.stream : "";
    harness.terminals[0]?.emitData("hello");
    await first.nextOutput();
    await first.close();
    await waitUntil(async () => (await rows(server))[0]?.releasedAt !== undefined);

    const second = await harness.openSocket(server, `stream=${stream}&resume=5`);
    assert.equal((await second.nextControl()).type, "ready");
    const [row] = await rows(server);
    assert.deepEqual(row, {
      paneId: "fixture",
      stream,
      startOffset: 0,
      endOffset: 5,
      claims: 2,
      resumeHits: 1,
      resumeMisses: 1,
      supersedes: 0,
      lastReadyOffset: 5,
      releasedAt: row?.releasedAt,
    });
    await second.close();
  } finally {
    await close(server);
  }
});

test("the chaos routes are authenticated like every other /api route", async () => {
  const harness = chaosHarness();
  const server = await harness.startServer();

  try {
    const anonymous = await chaosRequest(server, "fault", {
      method: "POST",
      credential: "",
      body: JSON.stringify({ kind: "hostPause", ms: 1_000 }),
    });
    assert.deepEqual(anonymous, { status: 401, body: { error: "Invalid access token." } });
    assert.equal((await chaosRequest(server, "events", { credential: "not-this-host's-token" })).status, 401);
    assert.equal(server.listening, true, "an unauthenticated fault must not have paused the host");
  } finally {
    await close(server);
  }
});

async function rows(server: Server): Promise<Array<Record<string, unknown>>> {
  const answer = await chaosRequest(server, "attachments");
  assert.equal(answer.status, 200);
  return answer.body.attachments as Array<Record<string, unknown>>;
}

function eventsHandshake(port: number): string {
  return [
    "GET /api/events HTTP/1.1",
    `Host: 127.0.0.1:${port}`,
    "Upgrade: websocket",
    "Connection: Upgrade",
    `Sec-WebSocket-Key: ${Buffer.from("0123456789abcdef").toString("base64")}`,
    "Sec-WebSocket-Version: 13",
    `Sec-WebSocket-Protocol: ${EVENTS_PROTOCOL}`,
    `Authorization: Bearer ${config.token}`,
    "",
    "",
  ].join("\r\n");
}
