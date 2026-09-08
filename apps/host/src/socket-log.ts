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
//
// Nothing the peer chose the text of is ever written. A close frame's reason
// and a request's path are both strings the other side composes, and a phone
// with a bug — or a phone that is not ours — can put a credential in either;
// truncating such a string only shortens the credential. So a close is logged
// as one of the reason codes below, chosen by the host from the numeric code,
// and a socket is named by the route the host matched it to (`kind`), never by
// the path the request asked for. `protocol` is safe for the same reason: the
// server's `handleProtocols` answers with one of its own constants or refuses
// the handshake, so it is never the peer's string either.

export type SocketKind = "events" | "terminal";

const COMPONENT = "socket";

// The host's own vocabulary for why a socket closed. The numeric code is
// logged beside it, so `other` still says exactly which code arrived — it just
// never carries the words that came with it.
const CLOSE_REASONS = new Map<number, string>([
  [1000, "normal"],
  [1001, "going-away"],
  [1002, "protocol-error"],
  [1005, "no-status"],
  [1006, "abnormal"],
  [1008, "policy"],
  [1009, "too-large"],
  [1011, "internal"],
  [4401, "revoked"],
]);

function closeReason(code: number): string {
  return CLOSE_REASONS.get(code) ?? "other";
}

const openedAt = new WeakMap<WebSocket, number>();
const deviceOf = new WeakMap<WebSocket, string>();
// Sockets the host itself ended, so the close line can say whose decision it
// was — the difference between "the phone gave up" and "we hung up on it".
const endedByHost = new WeakSet<WebSocket>();
let lastCensus = "";

export function socketOpened(
  websocket: WebSocket,
  kind: SocketKind,
  details: { device: string; protocol: string },
): void {
  openedAt.set(websocket, Date.now());
  deviceOf.set(websocket, details.device);
  // `kind` is the route: the host matched the upgrade to one of exactly two
  // handlers, and that is the whole of what the request's path could have
  // told anyone here.
  log.info(COMPONENT, "socket opened", { kind, device: details.device, protocol: details.protocol });
}

/** `code` is the peer's close code; the words it sent with it are dropped. */
export function socketClosed(websocket: WebSocket, kind: SocketKind, code: number): void {
  const opened = openedAt.get(websocket);
  openedAt.delete(websocket);
  log.info(COMPONENT, "socket closed", {
    kind,
    device: deviceOf.get(websocket) ?? "unknown",
    code,
    reason: closeReason(code),
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
