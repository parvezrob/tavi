import type { WebSocket } from "ws";
import type { AttachmentCounters } from "./attachment.js";
import { log } from "./log.js";

// Chaos mode (#111): a developer's host that injects the connection faults
// the phone's recovery paths are meant to survive — a socket that goes silent
// with TCP still up, a terminate with no close frame, an orderly close while
// output flows, and a host that answers nothing at all. Faults come only from
// the routes; `on` by itself injects nothing.
//
// Nothing here knows about herdr, attachments, or the events feed: sockets
// register their own hooks, and this file is bookkeeping plus timers. When
// chaos is off no `Chaos` is constructed and every hook site is a single
// `undefined` check.

export type ChaosFaultKind = "terminate" | "blackhole" | "closeMidOutput" | "hostPause";
export type ChaosSocketKind = "events" | "terminal";
export type ChaosCloseCode = 1011 | 1001;

export interface ChaosFaultRequest {
  kind: ChaosFaultKind;
  socket: ChaosSocketKind;
  paneId?: string;
  ms?: number;
  code?: ChaosCloseCode;
  thenSlowReadyMs?: number;
}

export interface ChaosFaultEvent extends ChaosFaultRequest {
  id: string;
  at: number;
  consumedByAttachAt?: number;
}

export type ChaosFaultOutcome = { ok: true; event: ChaosFaultEvent } | { ok: false; status: 404; error: string };

export interface ChaosAttachmentRow extends AttachmentCounters {
  paneId: string;
}

export interface ChaosSocketHooks {
  /** Drops application handling now, so frames the receiver still drains reach nothing. */
  detach(): void;
  /** Releases whatever the closed gate held: a retained snapshot, a flush, a close. */
  resume(): void;
}

export interface ChaosTerminalHooks extends ChaosSocketHooks {
  /** The pane's attachment counters, or undefined once that attachment is gone. */
  attachment(): AttachmentCounters | undefined;
}

export interface ChaosTimerHandle {
  /** Stops the timer if it has not run yet. */
  cancel(): void;
}

// Every window this file measures goes through one clock, so a test drives a
// 30 s blackhole without waiting 30 s (AGENTS.md, the fault-injection rule).
export interface ChaosClock {
  now(): number;
  setTimeout(run: () => void, ms: number): ChaosTimerHandle;
}

export interface Chaos {
  registerEventsSocket(websocket: WebSocket, hooks: ChaosSocketHooks): void;
  registerTerminalSocket(websocket: WebSocket, paneId: string, hooks: ChaosTerminalHooks): void;
  // True when this socket may write; false while a blackhole holds it. Only
  // the host's own frames pass through here — pongs are withheld by the read
  // pause, since a paused receiver never parses the ping that would earn one.
  gate(websocket: WebSocket): boolean;
  /** Ends a revoked socket's application handling (see the method's comment). */
  revoke(websocket: WebSocket): void;
  fault(request: ChaosFaultRequest): ChaosFaultOutcome;
  events(): ChaosFaultEvent[];
  attachments(): ChaosAttachmentRow[];
  hostPaused(): boolean;
  consumeSlowReady(paneId: string): number | undefined;
  /** The bridge's `slowReady` hold runs on the same clock as the faults. */
  setTimeout(run: () => void, ms: number): ChaosTimerHandle;
}

interface SocketEntry {
  kind: ChaosSocketKind;
  paneId: string | undefined;
  hooks: ChaosSocketHooks;
  gateOpen: boolean;
  pauseTimer: ChaosTimerHandle | undefined;
}

class ChaosHost implements Chaos {
  private readonly sockets = new Map<WebSocket, SocketEntry>();
  private readonly owners = new Map<string, WebSocket>();
  private readonly views = new Map<string, () => AttachmentCounters | undefined>();
  private readonly faults: ChaosFaultEvent[] = [];
  private readonly slowReady = new Map<string, { ms: number; fault?: ChaosFaultEvent }>();
  private readonly clock: ChaosClock;
  private hostPauseUntil = 0;
  private counter = 0;

  constructor(clock: ChaosClock) {
    this.clock = clock;
  }

  setTimeout(run: () => void, ms: number): ChaosTimerHandle {
    return this.clock.setTimeout(run, ms);
  }

  registerEventsSocket(websocket: WebSocket, hooks: ChaosSocketHooks): void {
    this.register(websocket, { kind: "events", paneId: undefined, hooks, gateOpen: true, pauseTimer: undefined });
  }

  registerTerminalSocket(websocket: WebSocket, paneId: string, hooks: ChaosTerminalHooks): void {
    this.register(websocket, { kind: "terminal", paneId, hooks, gateOpen: true, pauseTimer: undefined });
    this.owners.set(paneId, websocket);
    this.views.set(paneId, hooks.attachment);
  }

  gate(websocket: WebSocket): boolean {
    return this.sockets.get(websocket)?.gateOpen ?? true;
  }

  hostPaused(): boolean {
    return this.clock.now() < this.hostPauseUntil;
  }

  events(): ChaosFaultEvent[] {
    return this.faults;
  }

  attachments(): ChaosAttachmentRow[] {
    const rows: ChaosAttachmentRow[] = [];
    for (const [paneId, view] of [...this.views]) {
      const counters = view();
      // The attachment outlives its socket (retention), so a row survives a
      // drop; it goes when the attachment itself is gone.
      if (!counters) {
        this.views.delete(paneId);
        continue;
      }
      rows.push({ paneId, ...counters });
    }
    return rows;
  }

  consumeSlowReady(paneId: string): number | undefined {
    const armed = this.slowReady.get(paneId);
    if (!armed) return undefined;
    this.slowReady.delete(paneId);
    if (armed.fault) armed.fault.consumedByAttachAt = this.clock.now();
    return armed.ms;
  }

  // What a blackhole would otherwise do to a revocation, and what this undoes.
  // `ws.pause()` stops reading, not writing, so the 4401 close frame does go
  // out — but a paused socket never reads the peer's reply or its FIN, so
  // neither side finishes the closing handshake: the phone sits on a stuck
  // socket instead of reading 4401, and the pty and the events subscription
  // stay held, until ws's 30 s close timeout terminates it (measured: the
  // client's `close` does not fire inside 8 s without this). So drop the
  // application handling now — the attachment released, the listener
  // unsubscribed, before the un-pause hands the receiver's queued frames to
  // nobody — and un-pause, releasing nothing else the window was holding.
  revoke(websocket: WebSocket): void {
    const entry = this.sockets.get(websocket);
    if (!entry) return;
    entry.hooks.detach();
    entry.pauseTimer?.cancel();
    entry.pauseTimer = undefined;
    entry.gateOpen = true;
    websocket.resume();
  }

  fault(request: ChaosFaultRequest): ChaosFaultOutcome {
    if (request.kind === "hostPause") {
      this.hostPauseUntil = this.clock.now() + (request.ms ?? 0);
      return this.record(this.newEvent(request));
    }
    const targets = this.targets(request);
    if (targets.length === 0) return { ok: false, status: 404, error: "No socket to fault." };
    const event = this.newEvent(request);
    // Armed before the fault fires, so the attach the phone makes in reaction
    // can never arrive ahead of the arming.
    if (request.paneId !== undefined && request.thenSlowReadyMs !== undefined) {
      this.slowReady.set(request.paneId, { ms: request.thenSlowReadyMs, fault: event });
    }
    for (const websocket of targets) this.apply(request, websocket);
    return this.record(event);
  }

  private newEvent(request: ChaosFaultRequest): ChaosFaultEvent {
    this.counter += 1;
    return { id: `chaos-${this.counter}`, at: this.clock.now(), ...request };
  }

  private register(websocket: WebSocket, entry: SocketEntry): void {
    this.sockets.set(websocket, entry);
    const forget = () => this.forget(websocket);
    websocket.once("close", forget);
    websocket.once("error", forget);
  }

  private forget(websocket: WebSocket): void {
    const entry = this.sockets.get(websocket);
    if (!entry) return;
    entry.pauseTimer?.cancel();
    this.sockets.delete(websocket);
    if (entry.paneId === undefined || this.owners.get(entry.paneId) !== websocket) return;
    this.owners.delete(entry.paneId);
    // An attachment that died with its socket has no row; one that is merely
    // unowned keeps its row for the retention window the phone can resume in.
    if (this.views.get(entry.paneId)?.() === undefined) this.views.delete(entry.paneId);
  }

  private openGate(websocket: WebSocket, entry: SocketEntry): void {
    entry.pauseTimer = undefined;
    entry.gateOpen = true;
    websocket.resume();
    entry.hooks.resume();
  }

  private targets(request: ChaosFaultRequest): WebSocket[] {
    if (request.socket === "events") {
      return [...this.sockets.entries()].filter(([, entry]) => entry.kind === "events").map(([websocket]) => websocket);
    }
    const owner = request.paneId === undefined ? undefined : this.owners.get(request.paneId);
    return owner ? [owner] : [];
  }

  // `hostPause` never reaches here; `fault` answers it before it looks for a
  // socket, so the remaining kinds are the three that target one.
  private apply(request: ChaosFaultRequest, websocket: WebSocket): void {
    const entry = this.sockets.get(websocket);
    if (!entry) return;
    if (request.kind === "terminate") {
      websocket.terminate();
      return;
    }
    if (request.kind === "closeMidOutput") {
      websocket.close(request.code ?? 1011, "chaos");
      return;
    }
    websocket.pause();
    entry.gateOpen = false;
    entry.pauseTimer?.cancel();
    entry.pauseTimer = this.clock.setTimeout(() => this.openGate(websocket, entry), request.ms ?? 0);
  }

  private record(event: ChaosFaultEvent): ChaosFaultOutcome {
    this.faults.push(event);
    log.warn("chaos", `fault ${event.kind}`, {
      id: event.id,
      socket: event.socket,
      ...(event.paneId === undefined ? {} : { paneId: event.paneId }),
      ...(event.ms === undefined ? {} : { ms: event.ms }),
      ...(event.code === undefined ? {} : { code: event.code }),
      ...(event.thenSlowReadyMs === undefined ? {} : { thenSlowReadyMs: event.thenSlowReadyMs }),
    });
    return { ok: true, event };
  }
}

// The host's own clock: unref'd so a pending window never holds the process open.
const REAL_CLOCK: ChaosClock = {
  now: () => Date.now(),
  setTimeout: (run, ms) => {
    const timer = setTimeout(run, ms);
    timer.unref?.();
    return { cancel: () => clearTimeout(timer) };
  },
};

export function createChaos(clock: ChaosClock = REAL_CLOCK): Chaos {
  return new ChaosHost(clock);
}

export type ChaosStartup = { ok: true; enabled: boolean } | { ok: false; error: string };

/**
 * Whether this process may inject faults. Refused where a fault would reach
 * someone who did not ask for one: a production build, the managed runtime a
 * pairing installed, or an `npx` run. A checkout or `npm i -g` may.
 */
export function chaosStartup(
  value: string | undefined,
  runtime: { production: boolean; managed: boolean; ephemeral: boolean },
): ChaosStartup {
  if (value === undefined || value === "") return { ok: true, enabled: false };
  if (value !== "on") return { ok: false, error: "TAVI_CHAOS accepts only `on`." };
  if (runtime.production) return { ok: false, error: "TAVI_CHAOS is refused when NODE_ENV=production." };
  if (runtime.managed) {
    return { ok: false, error: "TAVI_CHAOS is refused on the managed runtime; run a checkout's host instead." };
  }
  if (runtime.ephemeral) return { ok: false, error: "TAVI_CHAOS is refused under npx; run a checkout's host instead." };
  return { ok: true, enabled: true };
}
