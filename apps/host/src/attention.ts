import { agentsFrame, type AgentEventSource, type AgentsListener, type HerdrAgentsSnapshot } from "./herdr-events.js";
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

  /** Sessions the hooks currently hold as blocked (expired ones dropped). */
  blockedSessions(): string[] {
    return [...this.blockedBySession.keys()].filter((sessionId) => this.isBlocked(sessionId));
  }

  /** Drops a block on evidence other than a hook (the screen shows no dialog). */
  clear(sessionId: string): boolean {
    if (!this.blockedBySession.delete(sessionId)) return false;
    this.notify();
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

// Hooks only ever say "a dialog appeared" and "a tool ran / the turn ended /
// a prompt was typed". Nothing fires when a person presses Esc on the
// dialog (Claude Code skips Stop on an interrupt and PostToolUse for a tool
// that never ran), denies it and walks away, or kills the session — so the
// overlay would pin "Needs you" on an idle agent for the whole TTL (owner
// hit exactly this). The screen is the tiebreaker: a permission dialog is
// defined by being on screen, and the host can already read the viewport
// (the phone's "Already resolved" sheet uses the same read). While anything
// is hook-blocked, poll its pane; two consecutive reads with no dialog clear
// the block. Two, not one, so a mid-repaint read cannot drop a real dialog;
// a read that fails outright never counts either way.
export interface AttentionReconcilerOptions {
  overlay: AttentionOverlay;
  /** The latest agents the feed knows, with their Claude session refs. */
  agents: () => readonly { id: string; sessionRef?: string | undefined }[];
  /** Whether a permission dialog is on the pane's screen; undefined = could not read. */
  dialogPresent: (paneId: string) => Promise<boolean | undefined>;
  intervalMilliseconds?: number;
  missesToClear?: number;
}

export class AttentionReconciler {
  private readonly misses = new Map<string, number>();
  private readonly interval: number;
  private readonly missesToClear: number;
  private timer: NodeJS.Timeout | undefined;
  private ticking = false;
  private unsubscribe: (() => void) | undefined;

  constructor(private readonly options: AttentionReconcilerOptions) {
    this.interval = options.intervalMilliseconds ?? 3_000;
    this.missesToClear = options.missesToClear ?? 2;
  }

  start(): void {
    if (this.unsubscribe) return;
    this.unsubscribe = this.options.overlay.subscribe(() => this.arm());
    this.arm();
  }

  stop(): void {
    this.unsubscribe?.();
    this.unsubscribe = undefined;
    this.disarm();
  }

  // The timer only runs while a block exists — an idle host does no reads.
  private arm(): void {
    if (this.timer || this.options.overlay.blockedSessions().length === 0) return;
    this.timer = setInterval(() => void this.tick(), this.interval);
    this.timer.unref?.();
  }

  private disarm(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    this.misses.clear();
  }

  async tick(): Promise<void> {
    if (this.ticking) return;
    this.ticking = true;
    try {
      const blocked = this.options.overlay.blockedSessions();
      if (blocked.length === 0) {
        this.disarm();
        return;
      }
      const agents = this.options.agents();
      for (const sessionId of blocked) {
        const agent = agents.find((candidate) => candidate.sessionRef === sessionId);
        // No pane carries this session any more: the dialog cannot be on
        // any screen. Counted like an empty screen so a killed session
        // clears on the same two-read rule.
        const present = agent ? await this.options.dialogPresent(agent.id) : false;
        if (present === undefined) continue;
        if (present) {
          this.misses.delete(sessionId);
          continue;
        }
        const count = (this.misses.get(sessionId) ?? 0) + 1;
        if (count >= this.missesToClear) {
          this.misses.delete(sessionId);
          this.options.overlay.clear(sessionId);
        } else {
          this.misses.set(sessionId, count);
        }
      }
      for (const sessionId of [...this.misses.keys()]) {
        if (!blocked.includes(sessionId)) this.misses.delete(sessionId);
      }
    } finally {
      this.ticking = false;
    }
  }
}

// Wraps the Herdr event feed so every published snapshot carries the
// overlay's verdict, and overlay changes republish immediately — the phone
// sees hook-reported blocks with the same sub-second latency as Herdr's own
// events.
export class AttentiveAgentEvents implements AgentEventSource {
  private readonly listeners = new Set<AgentsListener>();
  private detach: (() => void) | undefined;

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

  // One inner subscription for every phone, not one each: this wrapper merges
  // and serializes once per snapshot it publishes, never once per socket
  // (#68 finding 2). The feed underneath serializes its own pre-merge frame
  // for change detection, so a snapshot costs two envelopes in production —
  // two publishers, not two phones.
  subscribe(listener: AgentsListener): () => void {
    // Attach before the listener joins, so the inner feed's replay lands on
    // nobody and every subscriber is replayed the same way, right below.
    if (this.detach === undefined) this.attach();
    this.listeners.add(listener);
    const snapshot = this.latest;
    if (snapshot) listener(snapshot, agentsFrame(snapshot));
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size > 0) return;
      this.detach?.();
      this.detach = undefined;
    };
  }

  private attach(): void {
    const unsubscribeInner = this.inner.subscribe((snapshot) => this.fanOut(this.merge(snapshot)));
    const unsubscribeOverlay = this.overlay.subscribe(() => {
      const snapshot = this.inner.latest;
      if (snapshot) this.fanOut(this.merge(snapshot));
    });
    this.detach = () => {
      unsubscribeInner();
      unsubscribeOverlay();
    };
  }

  private fanOut(snapshot: HerdrAgentsSnapshot): void {
    if (this.listeners.size === 0) return;
    const frame = agentsFrame(snapshot);
    for (const listener of [...this.listeners]) listener(snapshot, frame);
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
