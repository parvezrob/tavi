import assert from "node:assert/strict";
import test from "node:test";
import { AttentionOverlay, AttentionReconciler, AttentiveAgentEvents, parseClaudeHookEvent } from "./attention.js";
import type { AgentEventSource, AgentsListener, HerdrAgentsSnapshot } from "./herdr-events.js";
import type { HerdrAgentInfo } from "./types.js";

const agent = (overrides: Partial<HerdrAgentInfo> = {}): HerdrAgentInfo => ({
  id: "wB:p1",
  agent: "claude",
  status: "idle",
  cwd: "/work",
  title: "",
  workspaceId: "wB",
  tabId: "wB:t1",
  focused: false,
  revision: 1,
  authority: "herdr",
  sessionRef: "sess-1",
  ...overrides,
});

test("parses claude hook payload field names", () => {
  const event = parseClaudeHookEvent({
    hook_event_name: "Notification",
    session_id: "sess-1",
    cwd: "/work",
    message: "Claude needs your permission to use Bash",
  });
  assert.deepEqual(event, {
    event: "Notification",
    sessionId: "sess-1",
    cwd: "/work",
    message: "Claude needs your permission to use Bash",
  });
  assert.equal(parseClaudeHookEvent({ session_id: "x" }), undefined);
});

test("permission notification blocks and lifecycle events resolve", () => {
  const overlay = new AttentionOverlay();

  assert.equal(overlay.report({ event: "Notification", sessionId: "sess-1", message: "needs your permission" }), true);
  assert.equal(overlay.isBlocked("sess-1"), true);

  // Idle reminders are not act-now facts.
  assert.equal(
    overlay.report({ event: "Notification", sessionId: "sess-2", message: "waiting for your input" }),
    false,
  );
  assert.equal(overlay.isBlocked("sess-2"), false);

  // SubagentStop must not clear the main agent's pending dialog.
  assert.equal(overlay.report({ event: "SubagentStop", sessionId: "sess-1" }), false);
  assert.equal(overlay.isBlocked("sess-1"), true);

  assert.equal(overlay.report({ event: "PostToolUse", sessionId: "sess-1" }), true);
  assert.equal(overlay.isBlocked("sess-1"), false);
});

test("hook-reported blocks expire after the ttl", () => {
  let now = 0;
  const overlay = new AttentionOverlay({ ttlMilliseconds: 1_000, now: () => now });
  overlay.report({ event: "Notification", sessionId: "sess-1", message: "permission" });
  now = 900;
  assert.equal(overlay.isBlocked("sess-1"), true);
  now = 1_100;
  assert.equal(overlay.isBlocked("sess-1"), false);
});

test("merged snapshots force blocked with hook authority and republish on overlay changes", () => {
  const overlay = new AttentionOverlay();
  const snapshot: HerdrAgentsSnapshot = { available: true, agents: [agent()] };
  const listeners = new Set<AgentsListener>();
  const inner: AgentEventSource = {
    start() {},
    stop() {},
    latest: snapshot,
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
  const source = new AttentiveAgentEvents(inner, overlay);
  const published: HerdrAgentsSnapshot[] = [];
  const frames: string[] = [];
  source.subscribe((published_, frame) => {
    published.push(published_);
    frames.push(frame);
  });
  // Subscribing replays the current state, as the herdr feed itself does.
  assert.equal(published.length, 1);

  overlay.report({ event: "Notification", sessionId: "sess-1", message: "permission to use Bash" });
  assert.equal(published.length, 2);
  assert.equal(published[1]?.agents[0]?.status, "blocked");
  assert.equal(published[1]?.agents[0]?.authority, "claude-hook");
  assert.equal(frames[1], JSON.stringify({ type: "agents", ...published[1] }));

  overlay.report({ event: "Stop", sessionId: "sess-1" });
  assert.equal(published[2]?.agents[0]?.status, "idle");
  assert.equal(published[2]?.agents[0]?.authority, "herdr");

  // Agents without a session ref are never touched.
  const detached = new AttentiveAgentEvents(inner, overlay);
  overlay.report({ event: "Notification", sessionId: "other", message: "permission" });
  const merged = detached.merge({ available: true, agents: [agent({ sessionRef: undefined })] });
  assert.equal(merged.agents[0]?.status, "idle");
});

// The screen tiebreaker: an Esc'd dialog fires no hook, so the overlay must
// yield to what the viewport shows.
test("reconciler clears a hook block after two reads with no dialog on screen", async () => {
  const overlay = new AttentionOverlay();
  overlay.report({ event: "PermissionRequest", sessionId: "sess-1" });
  const reads: string[] = [];
  const reconciler = new AttentionReconciler({
    overlay,
    agents: () => [agent()],
    dialogPresent: async (paneId) => {
      reads.push(paneId);
      return false;
    },
    intervalMilliseconds: 60_000,
  });

  await reconciler.tick();
  assert.equal(overlay.isBlocked("sess-1"), true, "one empty read is not enough — a repaint can blank a real dialog");
  await reconciler.tick();
  assert.equal(overlay.isBlocked("sess-1"), false);
  assert.deepEqual(reads, ["wB:p1", "wB:p1"]);
  reconciler.stop();
});

test("reconciler keeps the block while the dialog is on screen and resets the count", async () => {
  const overlay = new AttentionOverlay();
  overlay.report({ event: "PermissionRequest", sessionId: "sess-1" });
  const script = [false, true, false, false];
  const reconciler = new AttentionReconciler({
    overlay,
    agents: () => [agent()],
    dialogPresent: async () => script.shift() ?? false,
    intervalMilliseconds: 60_000,
  });

  await reconciler.tick(); // miss 1
  await reconciler.tick(); // present → count resets
  await reconciler.tick(); // miss 1 again
  assert.equal(overlay.isBlocked("sess-1"), true);
  await reconciler.tick(); // miss 2
  assert.equal(overlay.isBlocked("sess-1"), false);
  reconciler.stop();
});

test("reconciler ignores reads that fail and clears a session whose pane is gone", async () => {
  const overlay = new AttentionOverlay();
  overlay.report({ event: "PermissionRequest", sessionId: "sess-1" });
  overlay.report({ event: "PermissionRequest", sessionId: "sess-gone" });
  const reconciler = new AttentionReconciler({
    overlay,
    agents: () => [agent()],
    dialogPresent: async () => undefined,
    intervalMilliseconds: 60_000,
  });

  await reconciler.tick();
  await reconciler.tick();
  await reconciler.tick();
  assert.equal(overlay.isBlocked("sess-1"), true, "an unreadable pane never counts as resolved");
  assert.equal(overlay.isBlocked("sess-gone"), false, "no pane carries the session — nothing can be waiting");
  reconciler.stop();
});

test("reconciler polls on its own only while something is blocked", async () => {
  const overlay = new AttentionOverlay();
  let reads = 0;
  const reconciler = new AttentionReconciler({
    overlay,
    agents: () => [agent()],
    dialogPresent: async () => {
      reads += 1;
      return false;
    },
    intervalMilliseconds: 5,
  });
  reconciler.start();
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(reads, 0, "idle host, no reads");

  overlay.report({ event: "PermissionRequest", sessionId: "sess-1" });
  const deadline = Date.now() + 2_000;
  while (overlay.isBlocked("sess-1") && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.equal(overlay.isBlocked("sess-1"), false);
  const settled = reads;
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(reads, settled, "timer stops once nothing is blocked");
  reconciler.stop();
});
