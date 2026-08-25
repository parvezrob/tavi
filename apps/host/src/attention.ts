import type { AgentEventSource, HerdrAgentsSnapshot } from "./herdr-events.js";
import type { HerdrAgentInfo } from "./types.js";

// Herdr's agent_status is a screen-detection heuristic and can miss or lag
// a waiting permission dialog. Claude Code's own hooks are durable facts
// from the agent itself: a Notification hook fires the moment permission is
// requested, and later lifecycle hooks prove the dialog was dealt with.
// This overlay records those facts keyed by Claude session id and forces
// `blocked` (authority "claude-hook") onto the matching agent until the
// hook stream reports resolution — screen detection can no longer drop a
// genuinely waiting agent. Issue #22.

// A hook-reported block without any resolution eventually expires so a
// killed session cannot pin a phantom "Needs you" forever.
const DEFAULT_TTL_MILLISECONDS = 60 * 60 * 1_000;

export interface ClaudeHookEvent {
  event: string;
  sessionId: string;
  cwd?: string;
  message?: string;
}

// Hook payloads use Claude Code's field names; normalize defensively.
export function parseClaudeHookEvent(body: unknown): ClaudeHookEvent | undefined {
  if (typeof body !== "object" || body === null) return undefined;
  const record = body as Record<string, unknown>;
  const event = typeof record.hook_event_name === "string" ? record.hook_event_name : "";
  const sessionId = typeof record.session_id === "string" ? record.session_id : "";
  if (!event || !sessionId) return undefined;
  return {
    event,
    sessionId,
    ...(typeof record.cwd === "string" ? { cwd: record.cwd } : {}),
    ...(typeof record.message === "string" ? { message: record.message } : {}),
  };
}

export class AttentionOverlay {
  private readonly blockedBySession = new Map<string, { at: number }>();
  private readonly listeners = new Set<() => void>();
  private readonly now: () => number;
  private readonly ttl: number;

  constructor(options: { ttlMilliseconds?: number; now?: () => number } = {}) {
    this.now = options.now ?? Date.now;
    this.ttl = options.ttlMilliseconds ?? DEFAULT_TTL_MILLISECONDS;
  }

  // Returns true when the overlay changed (callers republish then).
  report(event: ClaudeHookEvent): boolean {
    switch (event.event) {
      // PermissionRequest (newer Claude Code) fires exactly when a
      // permission dialog is shown — no message filtering needed.
      case "PermissionRequest":
        this.blockedBySession.set(event.sessionId, { at: this.now() });
        this.notify();
        return true;
      case "Notification":
        // Notification also fires for idle reminders; only a permission
        // request is an "act now" fact.
        if (!/permission/i.test(event.message ?? "")) return false;
        this.blockedBySession.set(event.sessionId, { at: this.now() });
        this.notify();
        return true;
      // PostToolUse proves an approval was granted (the tool ran); Stop
      // ends the turn; a new user prompt means the human is engaged.
      // SubagentStop deliberately does NOT clear — the main agent's dialog
      // can still be waiting while a subagent finishes.
      case "PostToolUse":
      case "Stop":
      case "UserPromptSubmit": {
        if (!this.blockedBySession.delete(event.sessionId)) return false;
        this.notify();
        return true;
      }
      default:
        return false;
    }
  }

  isBlocked(sessionId: string | undefined): boolean {
    if (!sessionId) return false;
    const entry = this.blockedBySession.get(sessionId);
    if (!entry) return false;
    if (this.now() - entry.at > this.ttl) {
      this.blockedBySession.delete(sessionId);
      return false;
    }
    return true;
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  private notify(): void {
    for (const listener of [...this.listeners]) listener();
  }
}

// Wraps the Herdr event feed so every published snapshot carries the
// overlay's verdict, and overlay changes republish immediately — the phone
// sees hook-reported blocks with the same sub-second latency as Herdr's own
// events.
export class AttentiveAgentEvents implements AgentEventSource {
  constructor(
    private readonly inner: AgentEventSource,
    private readonly overlay: AttentionOverlay,
  ) {}

  get latest(): HerdrAgentsSnapshot | undefined {
    const snapshot = this.inner.latest;
    return snapshot ? this.merge(snapshot) : undefined;
  }

  start(): void {
    this.inner.start();
  }

  stop(): void {
    this.inner.stop();
  }

  subscribe(listener: (snapshot: HerdrAgentsSnapshot) => void): () => void {
    const unsubscribeInner = this.inner.subscribe((snapshot) => listener(this.merge(snapshot)));
    const unsubscribeOverlay = this.overlay.subscribe(() => {
      const snapshot = this.inner.latest;
      if (snapshot) listener(this.merge(snapshot));
    });
    return () => {
      unsubscribeInner();
      unsubscribeOverlay();
    };
  }

  merge(snapshot: HerdrAgentsSnapshot): HerdrAgentsSnapshot {
    if (!snapshot.available) return snapshot;
    return {
      ...snapshot,
      agents: snapshot.agents.map((agent) => this.apply(agent)),
    };
  }

  private apply(agent: HerdrAgentInfo): HerdrAgentInfo {
    if (!this.overlay.isBlocked(agent.sessionRef)) return agent;
    return { ...agent, status: "blocked", authority: "claude-hook" };
  }
}
