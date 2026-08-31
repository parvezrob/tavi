import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { createServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import test, { type TestContext } from "node:test";
import { HerdrEventFeed, type HerdrAgentsSnapshot } from "./herdr-events.js";
import { HerdrService } from "./herdr.js";

test("publishes a snapshot, refreshes on status events, and rebuilds on structural events", async (context) => {
  const socketPath = temporarySocketPath(context);
  const fake = await startScriptedHerdr(context, socketPath);
  fake.agents = [agentFixture("wB:p1", "working")];

  const feed = new HerdrEventFeed(new HerdrService({ socketPath }), {
    socketPath,
    reconnectDelayMilliseconds: 20,
    refreshDebounceMilliseconds: 5,
  });
  context.after(() => feed.stop());
  const snapshots: HerdrAgentsSnapshot[] = [];
  feed.subscribe((snapshot) => snapshots.push(snapshot));
  feed.start();

  await waitUntil(() => snapshots.length === 1);
  assert.equal(snapshots[0]?.available, true);
  assert.equal(snapshots[0]?.agents[0]?.status, "working");
  await waitUntil(() => fake.subscriptions.length === 1);
  assert.deepEqual(fake.subscriptions[0], [
    { type: "pane.created" },
    { type: "pane.closed" },
    { type: "pane.exited" },
    { type: "pane.agent_detected" },
    { type: "pane.updated" },
    { type: "tab.renamed" },
    { type: "pane.agent_status_changed", pane_id: "wB:p1" },
  ]);

  // A status event triggers a re-list; the new status is published.
  fake.agents = [agentFixture("wB:p1", "blocked")];
  fake.emit({ event: "pane_agent_status_changed", data: { pane_id: "wB:p1" } });
  await waitUntil(() => snapshots.length === 2);
  assert.equal(snapshots[1]?.agents[0]?.status, "blocked");

  // A structural event resubscribes against the fresh pane set.
  fake.agents = [agentFixture("wB:p1", "blocked"), agentFixture("wB:p9", "idle")];
  fake.emit({ event: "pane_created", data: { pane: { pane_id: "wB:p9" } } });
  await waitUntil(() => fake.subscriptions.length === 2);
  assert.deepEqual(fake.subscriptions[1]?.at(-1), {
    type: "pane.agent_status_changed",
    pane_id: "wB:p9",
  });
  await waitUntil(() => snapshots.some((snapshot) => snapshot.agents.length === 2));
});

test("publishes honest unavailability and recovers when herdr returns", async (context) => {
  const socketPath = temporarySocketPath(context);
  const feed = new HerdrEventFeed(new HerdrService({ socketPath }), {
    socketPath,
    reconnectDelayMilliseconds: 20,
    refreshDebounceMilliseconds: 5,
  });
  context.after(() => feed.stop());
  const snapshots: HerdrAgentsSnapshot[] = [];
  feed.subscribe((snapshot) => snapshots.push(snapshot));
  feed.start();

  await waitUntil(() => snapshots.length === 1);
  assert.equal(snapshots[0]?.available, false);
  assert.match(snapshots[0]?.reason ?? "", /not running/);

  const fake = await startScriptedHerdr(context, socketPath);
  fake.agents = [agentFixture("wB:p1", "idle")];
  await waitUntil(() => snapshots.some((snapshot) => snapshot.available));
  assert.equal(snapshots.at(-1)?.agents[0]?.id, "wB:p1");
});

function agentFixture(paneId: string, status: string): Record<string, unknown> {
  return {
    agent: "claude",
    agent_status: status,
    cwd: "/",
    pane_id: paneId,
    revision: 1,
    tab_id: "wB:t1",
    terminal_title_stripped: "Claude Code",
    workspace_id: "wB",
  };
}

interface ScriptedHerdr {
  agents: unknown[];
  subscriptions: Array<Array<Record<string, unknown>>>;
  emit(event: Record<string, unknown>): void;
}

async function startScriptedHerdr(context: TestContext, socketPath: string): Promise<ScriptedHerdr> {
  const eventSockets = new Set<Socket>();
  const scripted: ScriptedHerdr = {
    agents: [],
    subscriptions: [],
    emit(event) {
      for (const socket of eventSockets) {
        socket.write(`${JSON.stringify(event)}\n`);
      }
    },
  };

  const server = createServer((socket) => {
    let buffered = "";
    socket.on("data", (chunk) => {
      buffered += chunk.toString("utf8");
      let lineEnd = buffered.indexOf("\n");
      while (lineEnd !== -1) {
        const request = JSON.parse(buffered.slice(0, lineEnd)) as {
          id: string;
          method: string;
          params: Record<string, unknown>;
        };
        buffered = buffered.slice(lineEnd + 1);
        if (request.method === "ping") {
          socket.write(
            `${JSON.stringify({ id: request.id, result: { type: "pong", protocol: 17 } })}\n`,
          );
        } else if (request.method === "agent.list") {
          socket.write(
            `${JSON.stringify({ id: request.id, result: { type: "agent_list", agents: scripted.agents } })}\n`,
          );
        } else if (request.method === "tab.list") {
          // Real herdr always answers tab.list (the label join, #55).
          socket.write(
            `${JSON.stringify({ id: request.id, result: { type: "tab_list", tabs: [] } })}\n`,
          );
        } else if (request.method === "events.subscribe") {
          scripted.subscriptions.push(
            (request.params.subscriptions as Array<Record<string, unknown>>) ?? [],
          );
          eventSockets.add(socket);
          socket.once("close", () => eventSockets.delete(socket));
          socket.write(
            `${JSON.stringify({ id: request.id, result: { type: "subscription_started" } })}\n`,
          );
        }
        lineEnd = buffered.indexOf("\n");
      }
    });
  });
  context.after(() => {
    server.close();
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
  return scripted;
}

function temporarySocketPath(context: TestContext): string {
  const socketPath = path.join(tmpdir(), `mocha-events-${randomBytes(6).toString("hex")}.sock`);
  context.after(() => {
    // The socket file is removed when the server closes; nothing else to do.
  });
  return socketPath;
}

async function waitUntil(condition: () => boolean): Promise<void> {
  const deadline = Date.now() + 2_000;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error("Timed out waiting for feed state.");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}
