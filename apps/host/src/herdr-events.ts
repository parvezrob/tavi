import { createConnection, type Socket } from "node:net";
import type { HerdrAgentSource } from "./herdr.js";
import type { HerdrAgentInfo } from "./types.js";

const RECONNECT_DELAY_MILLISECONDS = 2_000;
const REFRESH_DEBOUNCE_MILLISECONDS = 150;

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
}

export interface AgentEventSource {
  start(): void;
  stop(): void;
  subscribe(listener: (snapshot: HerdrAgentsSnapshot) => void): () => void;
  readonly latest: HerdrAgentsSnapshot | undefined;
}

export interface HerdrEventFeedOptions {
  socketPath: string;
  reconnectDelayMilliseconds?: number;
  refreshDebounceMilliseconds?: number;
}

// Keeps one long-lived events.subscribe connection to Herdr and re-reads
// agent.list whenever anything fires: Herdr stays the only state authority,
// events are just change triggers, and snapshots can never miss a removal.
export class HerdrEventFeed implements AgentEventSource {
  private readonly listeners = new Set<(snapshot: HerdrAgentsSnapshot) => void>();
  private readonly options: HerdrEventFeedOptions;
  private readonly source: HerdrAgentSource;

  private lastPublished: string | undefined;
  private lastSnapshot: HerdrAgentsSnapshot | undefined;
  private refreshTimer: NodeJS.Timeout | undefined;
  private retryTimer: NodeJS.Timeout | undefined;
  private socket: Socket | undefined;
  private started = false;
  private stopped = false;
  private subscriptionCounter = 0;

  constructor(source: HerdrAgentSource, options: HerdrEventFeedOptions) {
    this.source = source;
    this.options = options;
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

  subscribe(listener: (snapshot: HerdrAgentsSnapshot) => void): () => void {
    this.listeners.add(listener);
    if (this.lastSnapshot) listener(this.lastSnapshot);
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

  private scheduleRefresh(): void {
    if (this.refreshTimer || this.stopped) return;
    this.refreshTimer = setTimeout(() => {
      this.refreshTimer = undefined;
      void this.refreshAgents();
    }, this.options.refreshDebounceMilliseconds ?? REFRESH_DEBOUNCE_MILLISECONDS);
    this.refreshTimer.unref?.();
  }

  private scheduleReconnect(): void {
    if (this.retryTimer || this.stopped) return;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = undefined;
      void this.establish();
    }, this.options.reconnectDelayMilliseconds ?? RECONNECT_DELAY_MILLISECONDS);
    this.retryTimer.unref?.();
  }

  // Returns the agent list when Herdr answered, undefined when unavailable.
  private async refreshAgents(): Promise<HerdrAgentInfo[] | undefined> {
    const result = await this.source.listAgents();
    if (this.stopped) return undefined;
    if (!result.available) {
      this.publish({
        available: false,
        reason: result.reason ?? "Herdr is unavailable.",
        agents: [],
      });
      return undefined;
    }
    this.publish({ available: true, agents: result.agents });
    return result.agents;
  }

  private publish(snapshot: HerdrAgentsSnapshot): void {
    this.lastSnapshot = snapshot;
    const serialized = JSON.stringify(snapshot);
    if (serialized === this.lastPublished) return;
    this.lastPublished = serialized;
    for (const listener of [...this.listeners]) {
      listener(snapshot);
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
