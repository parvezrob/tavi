import type { WebSocket } from "ws";
import { log } from "./log.js";

// What `~/.tavi/host.log` says about a phone's connection. Until now it held
// startup banners and nothing else, so when a phone reported a reconnect loop
// the computer's half of it could not be read at all — only the phone's.
//
// One line per lifecycle event, one named function each so the strings stay
// greppable, and never a token, a credential or a frame's contents: this log
// is read over someone's shoulder and pasted into issues. Nothing here fires
// per frame; the only recurring line is the census, and its caller gates it to
// once a minute.

export type SocketKind = "events" | "terminal";

const COMPONENT = "socket";
// A close reason is the peer's own text. It is bounded to 123 bytes on the
// wire and cut further here: the log wants to know why, not to carry a string
// somebody else chose the length of.
const MAX_REASON_CHARACTERS = 80;

const openedAt = new WeakMap<WebSocket, number>();
const deviceOf = new WeakMap<WebSocket, string>();
// Sockets the host itself ended, so the close line can say whose decision it
// was — the difference between "the phone gave up" and "we hung up on it".
const endedByHost = new WeakSet<WebSocket>();
let lastCensus = "";

export function socketOpened(
  websocket: WebSocket,
  kind: SocketKind,
  details: { device: string; path: string; protocol: string },
): void {
  openedAt.set(websocket, Date.now());
  deviceOf.set(websocket, details.device);
  log.info(COMPONENT, "socket opened", {
    kind,
    device: details.device,
    path: details.path,
    protocol: details.protocol,
  });
}

export function socketClosed(websocket: WebSocket, kind: SocketKind, code: number, reason: string): void {
  const opened = openedAt.get(websocket);
  openedAt.delete(websocket);
  log.info(COMPONENT, "socket closed", {
    kind,
    device: deviceOf.get(websocket) ?? "unknown",
    code,
    reason: reason.slice(0, MAX_REASON_CHARACTERS),
    openMs: opened === undefined ? 0 : Date.now() - opened,
    byHost: endedByHost.has(websocket),
  });
}

/** The `keepAlive` second-miss path (#111), named in the log as exactly that. */
export function heartbeatTerminated(websocket: WebSocket, sinceLastPongMs: number): void {
  endedByHost.add(websocket);
  log.warn(COMPONENT, "heartbeat terminate: two unanswered pings", {
    kind: "events",
    device: deviceOf.get(websocket) ?? "unknown",
    sinceLastPongMs,
  });
}

export function credentialRevoked(websocket: WebSocket, kind: SocketKind): void {
  endedByHost.add(websocket);
  log.warn(COMPONENT, "credential revoked", { kind, device: deviceOf.get(websocket) ?? "unknown", code: 4401 });
}

/** Marks a close the host chose, for any reason the functions above do not name. */
export function hostClosing(websocket: WebSocket): void {
  endedByHost.add(websocket);
}

/** Says how many sockets are open, and only when that is news. */
export function socketCensus(events: number, terminals: number): void {
  const counts = `${events}:${terminals}`;
  if (counts === lastCensus) return;
  lastCensus = counts;
  log.info(COMPONENT, "sockets open", { events, terminals });
}
