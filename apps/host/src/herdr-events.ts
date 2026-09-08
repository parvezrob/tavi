import { createConnection, type Socket } from "node:net";
import { SHELL_KIND } from "./agent-kinds.js";
import { HELD_SNAPSHOT_GRACE_MILLISECONDS, HeldSnapshot } from "./herdr-snapshot-hold.js";
import type { HerdrAgentSource } from "./herdr-types.js";
import type { HerdrAgentInfo } from "./types.js";

const RECONNECT_DELAY_MILLISECONDS = 2_000;
const REFRESH_DEBOUNCE_MILLISECONDS = 150;
// After Tavi releases a Terminal pane to herdr's detection (#66) the pane
// may be unlisted for a moment before herdr labels it; only after this long
// is "unlisted" read as "the agent exited, give the Terminal back".
const DETECTION_GRACE_MILLISECONDS = 5_000;
// A pane handed back and re-reported as shell while herdr still sees the same
// agent label is tried again this much later, a few times, then left alone.
const RELEASE_RETRY_MILLISECONDS = 30_000;
const RELEASE_RETRY_LIMIT = 3;

// Global pane lifecycle events (no pane_id); a per-pane status subscription
// is added for every agent pane known at subscribe time. Any structural
// change tears the subscription down and rebuilds it against a fresh list.
const STRUCTURAL_SUBSCRIPTIONS = [
  "pane.created",
  "pane.closed",
  "pane.exited",
  // Fires when an agent appears in an already-existing pane — without it a
  // freshly started claude/codex is invisible until some other event fires.
  "pane.agent_detected",
];
// Refresh-only triggers: an agent leaving a pane that stays open, and a
// tab getting a new name (#55) — the label rides the agent payload, so a
// rename must push a fresh list to every phone.
const REFRESH_SUBSCRIPTIONS = ["pane.updated", "tab.renamed"];

export interface HerdrAgentsSnapshot {
  available: boolean;
  reason?: string;
  agents: HerdrAgentInfo[];
  // Epoch milliseconds of the herdr reply this list came from — present only
  // while the host is serving a *held* list because herdr has not answered
  // since (see herdr-snapshot-hold.ts). Absent means "fresh, as of now",
  // which is what every snapshot before this field was. Additive and
  // optional: a decoder that ignores it reads exactly what it read before.
  asOf?: number;
}

// The listener is handed the snapshot *and* the exact text every phone gets:
// the `{type:"agents", …}` envelope is serialized once per publisher, never
// once per open socket (#68 finding 2).
export type AgentsListener = (snapshot: HerdrAgentsSnapshot, frame: string) => void;

export interface AgentEventSource {
  start(): void;
  stop(): void;
  subscribe(listener: AgentsListener): () => void;
  readonly latest: HerdrAgentsSnapshot | undefined;
}

/** The one text frame the events socket carries. */
export function agentsFrame(snapshot: HerdrAgentsSnapshot): string {
  return JSON.stringify({ type: "agents", ...snapshot });
}

export interface HerdrEventFeedOptions {
  socketPath: string;
  reconnectDelayMilliseconds?: number;
  refreshDebounceMilliseconds?: number;
  heldSnapshotGraceMilliseconds?: number;
}

// Keeps one long-lived events.subscribe connection to Herdr and re-reads
// agent.list whenever anything fires: Herdr stays the only state authority,
// events are just change triggers, and snapshots can never miss a removal.
export class HerdrEventFeed implements AgentEventSource {
  private readonly listeners = new Set<AgentsListener>();
  private readonly options: HerdrEventFeedOptions;
  private readonly source: HerdrAgentSource;

  private lastPublished: string | undefined;
  private lastSnapshot: HerdrAgentsSnapshot | undefined;
  // What the phones keep seeing while herdr is merely slow (#111).
  private readonly hold: HeldSnapshot;
  // Terminal panes handed back to herdr's detection (#66): when released,
  // and what was re-reported for them since. See reconcileShellPanes.
  private readonly released = new Map<string, { at: number; label: string }>();
  private readonly restored = new Map<string, { at: number; label: string; attempts: number }>();
  private reconciling = false;
  private refreshTimer: NodeJS.Timeout | undefined;
  private refreshDueAt = 0;
  private retryTimer: NodeJS.Timeout | undefined;
  private socket: Socket | undefined;
  private started = false;
  private stopped = false;
  private subscriptionCounter = 0;

  constructor(source: HerdrAgentSource, options: HerdrEventFeedOptions) {
    this.source = source;
    this.options = options;
    this.hold = new HeldSnapshot(options.heldSnapshotGraceMilliseconds ?? HELD_SNAPSHOT_GRACE_MILLISECONDS);
  }

  get latest(): HerdrAgentsSnapshot | undefined {
    return this.lastSnapshot;
  }

  start(): void {
    if (this.started) return;
    this.started = true;
    void this.establish();
  }

  stop(): void {
    this.stopped = true;
    this.clearTimers();
    this.teardownSocket();
    this.listeners.clear();
  }

  subscribe(listener: AgentsListener): () => void {
    this.listeners.add(listener);
    if (this.lastSnapshot && this.lastPublished) listener(this.lastSnapshot, this.lastPublished);
    return () => {
      this.listeners.delete(listener);
    };
  }

  private async establish(): Promise<void> {
    if (this.stopped) return;
    this.teardownSocket();

    const agents = await this.refreshAgents();
    if (this.stopped) return;
    if (agents === undefined) {
      this.scheduleReconnect();
      return;
    }

    const socket = createConnection({ path: this.options.socketPath });
    this.socket = socket;
    let buffered = "";
    let acknowledged = false;

    socket.on("connect", () => {
      const subscriptions = [
        ...STRUCTURAL_SUBSCRIPTIONS.map((type) => ({ type })),
        ...REFRESH_SUBSCRIPTIONS.map((type) => ({ type })),
        ...agents.map((agent) => ({ type: "pane.agent_status_changed", pane_id: agent.id })),
      ];
      // biome-ignore lint/suspicious/noAssignInExpressions: the id must be unique per subscription, and the counter has no other reader.
      const id = `tavi:events:${(this.subscriptionCounter += 1)}`;
      socket.write(`${JSON.stringify({ id, method: "events.subscribe", params: { subscriptions } })}\n`);
    });
    socket.on("data", (chunk) => {
      buffered += chunk.toString("utf8");
      let lineEnd = buffered.indexOf("\n");
      while (lineEnd !== -1) {
        const line = buffered.slice(0, lineEnd);
        buffered = buffered.slice(lineEnd + 1);
        this.handleLine(socket, line, () => {
          acknowledged = true;
        });
        lineEnd = buffered.indexOf("\n");
      }
    });
    const recover = () => {
      if (this.stopped || this.socket !== socket) return;
      this.teardownSocket();
      this.scheduleReconnect();
      // The stream died after being live; whatever changed meanwhile is
      // only visible through a fresh list, published by re-establishing.
      void acknowledged;
    };
    socket.on("error", recover);
    socket.on("close", recover);
  }

  private handleLine(socket: Socket, line: string, markAcknowledged: () => void): void {
    let message: Record<string, unknown>;
    try {
      message = JSON.parse(line) as Record<string, unknown>;
    } catch {
      // A line herdr sent that is not JSON tells us nothing; the next line
      // (or the next full snapshot) is what the feed acts on.
      return;
    }

    if (typeof message.id === "string") {
      const result = message.result as Record<string, unknown> | undefined;
      if (result?.type === "subscription_started") {
        markAcknowledged();
        return;
      }
      if (message.error !== undefined) {
        // Subscription rejected (e.g. a pane vanished between list and
        // subscribe): rebuild against a fresh list.
        if (this.socket === socket) {
          this.teardownSocket();
          this.scheduleReconnect();
        }
      }
      return;
    }

    const eventName = typeof message.event === "string" ? message.event : "";
    if (!eventName) return;
    if (
      eventName === "pane_created" ||
      eventName === "pane_closed" ||
      eventName === "pane_exited" ||
      eventName === "pane_agent_detected"
    ) {
      if (this.socket === socket) {
        this.teardownSocket();
        void this.establish();
      }
      return;
    }
    this.scheduleRefresh();
  }

  // An earlier refresh always wins over a later pending one: the grace-window
  // re-check (#66) must never hold up an event that arrived meanwhile.
  private scheduleRefresh(delayMilliseconds?: number): void {
    if (this.stopped) return;
    const delay = delayMilliseconds ?? this.options.refreshDebounceMilliseconds ?? REFRESH_DEBOUNCE_MILLISECONDS;
    const dueAt = Date.now() + delay;
    if (this.refreshTimer) {
      if (dueAt >= this.refreshDueAt) return;
      clearTimeout(this.refreshTimer);
    }
    this.refreshDueAt = dueAt;
    this.refreshTimer = setTimeout(() => {
      this.refreshTimer = undefined;
      void this.refreshUntilFresh();
    }, delay);
    this.refreshTimer.unref?.();
  }

  // A Terminal Tavi created is reported to herdr as "shell", and herdr keeps
  // that label over its own detection for the pane's life (#66) — so a
  // `claude` started inside stayed "Terminal / idle" and its needs-you was
  // muted. Two moves, both after every list: hand a shell pane back to
  // herdr's detection as soon as detection has a label for it (the next list
  // reads agent "claude" with a real status), and when that agent exits —
  // the pane drops out of agent.list while still existing — report it as
  // shell again so the Terminal stays on the phone instead of vanishing.
  private async reconcileShellPanes(agents: HerdrAgentInfo[]): Promise<void> {
    const source = this.source;
    if (!source.releaseShellAuthority || !source.reportShellPane || !source.paneExists) return;
    if (this.reconciling || this.stopped) return;
    this.reconciling = true;
    try {
      const now = Date.now();
      let changed = false;
      for (const agent of agents) {
        if (agent.agent !== SHELL_KIND || !agent.detectedAgent || agent.detectedAgent === SHELL_KIND) continue;
        const restored = this.restored.get(agent.id);
        if (
          restored &&
          restored.label === agent.detectedAgent &&
          (restored.attempts >= RELEASE_RETRY_LIMIT || now - restored.at < RELEASE_RETRY_MILLISECONDS)
        ) {
          continue;
        }
        try {
          await source.releaseShellAuthority(agent.id);
          this.released.set(agent.id, { at: now, label: agent.detectedAgent });
          changed = true;
        } catch {
          // Herdr said no (pane gone, or an older herdr); the next list tries again.
        }
      }
      const listed = new Set(agents.map((agent) => agent.id));
      for (const [paneId, release] of this.released) {
        if (listed.has(paneId)) continue;
        if (now - release.at < DETECTION_GRACE_MILLISECONDS) {
          this.scheduleRefresh(DETECTION_GRACE_MILLISECONDS);
          continue;
        }
        this.released.delete(paneId);
        if (!(await source.paneExists(paneId))) {
          this.restored.delete(paneId);
          continue;
        }
        try {
          await source.reportShellPane(paneId);
          const previous = this.restored.get(paneId);
          this.restored.set(paneId, {
            at: now,
            label: release.label,
            attempts: previous && previous.label === release.label ? previous.attempts + 1 : 1,
          });
          changed = true;
        } catch {
          // Pane vanished between the check and the report; nothing to restore.
        }
      }
      if (changed) this.scheduleRefresh();
    } finally {
      this.reconciling = false;
    }
  }

  private scheduleReconnect(): void {
    if (this.retryTimer || this.stopped) return;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = undefined;
      void this.establish();
    }, this.options.reconnectDelayMilliseconds ?? RECONNECT_DELAY_MILLISECONDS);
    this.retryTimer.unref?.();
  }

  // Returns the agent list when Herdr answered, undefined when it did not —
  // whether or not the last good list is being held on the wire meanwhile.
  private async refreshAgents(): Promise<HerdrAgentInfo[] | undefined> {
    const result = await this.source.listAgents();
    if (this.stopped) return undefined;
    if (!result.available) {
      this.publish(this.hold.onFailure(result.reason ?? "Herdr is unavailable."));
      return undefined;
    }
    const agents = this.withReleasedPanes(result.agents);
    this.hold.remember(agents);
    this.publish({ available: true, agents });
    void this.reconcileShellPanes(result.agents);
    return agents;
  }

  // A refresh that failed over a *live* events socket has nothing to wake it
  // again: herdr is slow, not gone, so no socket error fires the reconnect
  // loop. While a held list is on the wire the feed therefore retries on its
  // own, so the hold ends in a fresh list rather than in the grace expiring
  // — which is what "Tavi keeps retrying" has to mean. Bounded by the grace:
  // once the hold is over, this loop stops and the reconnect loop owns it.
  private async refreshUntilFresh(): Promise<void> {
    const agents = await this.refreshAgents();
    if (agents === undefined && this.hold.holding) {
      this.scheduleRefresh(this.options.reconnectDelayMilliseconds ?? RECONNECT_DELAY_MILLISECONDS);
    }
  }

  // Between Tavi releasing a Terminal pane and herdr's detection labelling
  // it (a second or two, #66) the pane is in no list at all. The phone
  // would show the row vanish and come back as Claude; carrying the last
  // known entry through the grace window keeps the row still, and the
  // relabelled entry replaces it on the next list.
  private withReleasedPanes(agents: HerdrAgentInfo[]): HerdrAgentInfo[] {
    if (this.released.size === 0 || !this.lastSnapshot) return agents;
    const now = Date.now();
    const listed = new Set(agents.map((agent) => agent.id));
    const carried = this.lastSnapshot.agents.filter((agent) => {
      const release = this.released.get(agent.id);
      return release !== undefined && !listed.has(agent.id) && now - release.at < DETECTION_GRACE_MILLISECONDS;
    });
    return carried.length === 0 ? agents : [...agents, ...carried];
  }

  private publish(snapshot: HerdrAgentsSnapshot): void {
    this.lastSnapshot = snapshot;
    // The envelope is both the change detector and the wire text, so a
    // snapshot costs this feed one JSON.stringify however many phones listen.
    const frame = agentsFrame(snapshot);
    if (frame === this.lastPublished) return;
    this.lastPublished = frame;
    for (const listener of [...this.listeners]) {
      listener(snapshot, frame);
    }
  }

  private teardownSocket(): void {
    const socket = this.socket;
    this.socket = undefined;
    socket?.removeAllListeners();
    socket?.destroy();
  }

  private clearTimers(): void {
    if (this.refreshTimer) clearTimeout(this.refreshTimer);
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.refreshTimer = undefined;
    this.retryTimer = undefined;
  }
}
