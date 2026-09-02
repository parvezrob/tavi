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

// #66: a Terminal Tavi reported as "shell" is handed back to herdr's
// detection the moment detection has a label for it, and reported as shell
// again when that agent exits and the pane drops out of the list.
test("hands a reported shell pane to herdr's detection and takes it back when the agent exits", async (context) => {
  const socketPath = temporarySocketPath(context);
  const fake = await startScriptedHerdr(context, socketPath);
  fake.panes.add("wB:p7");
  fake.agents = [shellFixture("wB:p7")];
  const feed = new HerdrEventFeed(new HerdrService({ socketPath }), {
    socketPath,
    reconnectDelayMilliseconds: 50,
    refreshDebounceMilliseconds: 10,
  });
  context.after(() => feed.stop());
  const snapshots: HerdrAgentsSnapshot[] = [];
  feed.subscribe((snapshot) => snapshots.push(snapshot));
  feed.start();
  await waitUntil(() => snapshots.length === 1);
  // A plain Terminal is left alone.
  assert.deepEqual(fake.authorityCalls, []);

  // claude starts inside: herdr's detection labels the session, the list
  // still says "shell". Tavi releases its report.
  fake.agents = [{ ...shellFixture("wB:p7"), agent_session: { agent: "claude", kind: "id", value: "s-1" } }];
  fake.emit({ event: "pane_agent_detected", data: { pane_id: "wB:p7" } });
  await waitUntil(() => fake.authorityCalls.length === 1);
  assert.deepEqual(fake.authorityCalls[0], {
    method: "pane.release_agent",
    params: { pane_id: "wB:p7", source: "tavi", agent: "shell" },
  });
  assert.equal(snapshots.at(-1)?.agents[0]?.detectedAgent, "claude");

  // Herdr has dropped the report and not yet relabelled: the pane is in no
  // list. The phone keeps seeing the Terminal through the grace window.
  fake.agents = [];
  fake.emit({ event: "pane_updated", data: { pane_id: "wB:p7" } });
  await new Promise((resolve) => setTimeout(resolve, 60));
  assert.equal(snapshots.at(-1)?.agents[0]?.id, "wB:p7", "the released pane vanished from the snapshot");
  assert.equal(fake.authorityCalls.length, 1);

  // Herdr now lists it as claude; nothing more to do.
  fake.agents = [{ ...agentFixture("wB:p7", "working"), agent_session: { agent: "claude", kind: "id", value: "s-1" } }];
  fake.emit({ event: "pane_agent_status_changed", data: { pane_id: "wB:p7" } });
  await waitUntil(() => snapshots.at(-1)?.agents[0]?.agent === "claude");
  assert.equal(snapshots.at(-1)?.agents[0]?.detectedAgent, undefined);
  assert.equal(fake.authorityCalls.length, 1);

  // claude exits: the pane leaves agent.list but still exists — the
  // Terminal comes back (after the detection grace, shortened here by
  // pretending the release happened long ago).
  (feed as unknown as { released: Map<string, { at: number; label: string }> }).released.set("wB:p7", {
    at: Date.now() - 60_000,
    label: "claude",
  });
  fake.agents = [];
  fake.emit({ event: "pane_updated", data: { pane_id: "wB:p7" } });
  await waitUntil(() => fake.authorityCalls.length === 2);
  assert.deepEqual(fake.authorityCalls[1], {
    method: "pane.report_agent",
    params: { pane_id: "wB:p7", source: "tavi", agent: "shell", state: "idle" },
  });

  // A pane that is gone for good is not reported into existence.
  fake.panes.clear();
  (feed as unknown as { released: Map<string, { at: number; label: string }> }).released.set("wB:p7", {
    at: Date.now() - 60_000,
    label: "claude",
  });
  fake.emit({ event: "pane_closed", data: { pane_id: "wB:p7" } });
  await waitUntil(() => snapshots.length >= 4);
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(fake.authorityCalls.length, 2);
});

function shellFixture(paneId: string): Record<string, unknown> {
  return { ...agentFixture(paneId, "idle"), agent: "shell", terminal_title_stripped: "zsh" };
}

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
  // Pane ids pane.get answers for (#66); everything else is "gone".
  panes: Set<string>;
  subscriptions: Array<Array<Record<string, unknown>>>;
  // Every pane.report_agent / pane.release_agent the feed sent, in order.
  authorityCalls: Array<{ method: string; params: Record<string, unknown> }>;
  emit(event: Record<string, unknown>): void;
}

async function startScriptedHerdr(context: TestContext, socketPath: string): Promise<ScriptedHerdr> {
  const eventSockets = new Set<Socket>();
  const scripted: ScriptedHerdr = {
    agents: [],
    panes: new Set(),
    subscriptions: [],
    authorityCalls: [],
    emit(event) {
      for (const socket of eventSockets) {
        socket.write(`${JSON.stringify(event)}\n`);
      }
    },
  };

  const openSockets = new Set<Socket>();
  const server = createServer((socket) => {
    // The feed under test tears its side down in context.after; a reply
    // still in flight then hits a closed pipe. That is expected, never a
    // test failure (it surfaced as a CI-only "write EPIPE" after the test).
    openSockets.add(socket);
    socket.on("error", () => undefined);
    socket.once("close", () => openSockets.delete(socket));
    let buffered = "";
    socket.on("data", (chunk) => {
      if (!socket.writable) return;
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
        } else if (request.method === "pane.release_agent" || request.method === "pane.report_agent") {
          scripted.authorityCalls.push({ method: request.method, params: request.params });
          socket.write(`${JSON.stringify({ id: request.id, result: { type: "ok" } })}\n`);
        } else if (request.method === "pane.get") {
          const paneId = String(request.params.pane_id);
          socket.write(
            scripted.panes.has(paneId)
              ? `${JSON.stringify({ id: request.id, result: { type: "pane_info", pane: { pane_id: paneId } } })}\n`
              : `${JSON.stringify({ id: request.id, error: { code: "pane_not_found", message: "gone" } })}\n`,
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
    for (const socket of openSockets) socket.destroy();
    server.close();
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
  return scripted;
}

function temporarySocketPath(context: TestContext): string {
  const socketPath = path.join(tmpdir(), `tavi-events-${randomBytes(6).toString("hex")}.sock`);
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
