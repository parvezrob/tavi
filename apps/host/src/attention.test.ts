import assert from "node:assert/strict";
import test from "node:test";
import { AttentionOverlay, AttentiveAgentEvents, parseClaudeHookEvent } from "./attention.js";
import type { AgentEventSource, HerdrAgentsSnapshot } from "./herdr-events.js";
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

  assert.equal(
    overlay.report({ event: "Notification", sessionId: "sess-1", message: "needs your permission" }),
    true,
  );
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
  const listeners = new Set<(published: HerdrAgentsSnapshot) => void>();
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
  source.subscribe((published_) => published.push(published_));

  overlay.report({ event: "Notification", sessionId: "sess-1", message: "permission to use Bash" });
  assert.equal(published.length, 1);
  assert.equal(published[0]?.agents[0]?.status, "blocked");
  assert.equal(published[0]?.agents[0]?.authority, "claude-hook");

  overlay.report({ event: "Stop", sessionId: "sess-1" });
  assert.equal(published[1]?.agents[0]?.status, "idle");
  assert.equal(published[1]?.agents[0]?.authority, "herdr");

  // Agents without a session ref are never touched.
  const detached = new AttentiveAgentEvents(inner, overlay);
  overlay.report({ event: "Notification", sessionId: "other", message: "permission" });
  const merged = detached.merge({ available: true, agents: [agent({ sessionRef: undefined })] });
  assert.equal(merged.agents[0]?.status, "idle");
});
