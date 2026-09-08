import type { IncomingMessage } from "node:http";
import type { Duplex } from "node:stream";
import type * as pty from "node-pty";
import type { WebSocket, WebSocketServer } from "ws";
import type { Chaos } from "./chaos.js";
import type { HostConfig } from "./config.js";
import type { HerdrAgentSource } from "./herdr-types.js";
import { agentsFrame, type AgentEventSource } from "./herdr-events.js";
import { EVENTS_PROTOCOL, TERMINAL_PROTOCOL, TERMINAL_PROTOCOL_V2 } from "./protocol.js";
import { keepAlive } from "./socket-heartbeat.js";
import { parseResumeRequest, spawnAttachmentTerminal, type TerminalTarget } from "./terminal-bridge.js";
import { safeSessionId } from "./validation.js";

// The two WebSocket upgrades the host answers (#46, #53): the events stream
// every paired phone holds open, and one agent pane's terminal. Split out of
// server.ts in #98 — both are a hand-written HTTP handshake on a raw socket,
// with their own protocol negotiation and their own refusals, and neither is
// the request dispatcher's business.

interface UpgradeCommon {
  request: IncomingMessage;
  socket: Duplex;
  head: Buffer;
  authorized: (request: IncomingMessage) => boolean;
  keepAuthorized: (websocket: WebSocket, request: IncomingMessage) => void;
}

// The events stream (#46): one open socket per phone, carrying the whole
// agent list on every change.
export function upgradeEvents(
  options: UpgradeCommon & {
    eventsWss: WebSocketServer;
    agentEvents: AgentEventSource | undefined;
    chaos: Chaos | undefined;
  },
): void {
  const { request, socket, head, eventsWss, authorized, keepAuthorized, agentEvents, chaos } = options;
  if (!authorized(request)) {
    socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }
  if (!offersEventsProtocol(request)) {
    socket.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }
  eventsWss.handleUpgrade(request, socket, head, (websocket) => {
    keepAuthorized(websocket, request);
    serveAgentEvents(websocket, agentEvents, chaos);
  });
}

// One agent pane's terminal. Herdr agents are terminal targets only when
// Herdr itself confirms them; a down Herdr degrades honestly instead of
// guessing.
export async function upgradeTerminal(
  options: UpgradeCommon & {
    url: URL;
    wss: WebSocketServer;
    herdr: HerdrAgentSource | undefined;
    config: HostConfig;
    spawnTerminal: typeof pty.spawn;
  },
): Promise<void> {
  const { request, socket, head, url, wss, authorized, keepAuthorized, herdr, config, spawnTerminal } = options;
  const agentMatch = url.pathname.match(/^\/api\/agents\/([^/]+)\/terminal$/);
  if (!agentMatch || !authorized(request)) {
    socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }
  if (!offersTerminalProtocol(request)) {
    socket.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }

  const paneId = safeSessionId(agentMatch[1] || "");
  if (!herdr) {
    socket.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }
  // A Terminal being handed to herdr's detection (#66) is unlisted for
  // a second or two; a reconnect landing in that window must not read
  // as "pane gone" — that failure is permanent on the phone.
  let lookup = await herdr.findAgent(paneId);
  for (let attempt = 0; attempt < 3 && lookup.available && !lookup.agent; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 1_000));
    lookup = await herdr.findAgent(paneId);
  }
  if (!lookup.available) {
    socket.write("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }
  if (!lookup.agent) {
    socket.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }
  const target: TerminalTarget = {
    key: `agent:${paneId}`,
    paneId,
    spawn: () => spawnAttachmentTerminal(herdr.attachCommand(paneId), config, spawnTerminal),
    detachedSize: () => herdr.paneSize?.(paneId) ?? Promise.resolve(undefined),
  };

  const resume = parseResumeRequest(url);
  wss.handleUpgrade(request, socket, head, (websocket) => {
    keepAuthorized(websocket, request);
    wss.emit("connection", websocket, request, target, resume);
  });
}

// Snapshot-based push: the phone always receives the full agent list, so a
// missed frame can never leave a stale agent on screen.
function serveAgentEvents(websocket: WebSocket, agentEvents?: AgentEventSource, chaos?: Chaos): void {
  keepAlive(websocket, {
    ...(chaos ? { clock: chaos, gate: (socket: WebSocket) => chaos.gate(socket) } : {}),
  });
  // Chaos only (#111): a blackholed socket keeps the *latest* frame it skipped
  // and sends that one when the window ends — a snapshot is the whole list, so
  // replaying the older ones would only paint stale state.
  let retained: string | undefined;
  const send = (frame: string) => {
    if (websocket.readyState !== websocket.OPEN) return;
    if (chaos && !chaos.gate(websocket)) {
      retained = frame;
      return;
    }
    websocket.send(frame);
  };

  let unsubscribe: () => void = () => undefined;
  chaos?.registerEventsSocket(websocket, {
    detach: () => unsubscribe(),
    resume: () => {
      const held = retained;
      retained = undefined;
      if (held) send(held);
    },
  });

  if (!agentEvents) {
    send(agentsFrame({ available: false, reason: "Herdr integration is not configured on this host.", agents: [] }));
    return;
  }

  // The frame arrives already serialized: one envelope per snapshot, shared by
  // every phone, instead of one JSON.stringify per socket (#68 finding 2).
  unsubscribe = agentEvents.subscribe((_snapshot, frame) => send(frame));
  if (!agentEvents.latest) {
    send(agentsFrame({ available: false, reason: "Waiting for the first Herdr snapshot.", agents: [] }));
  }
  websocket.once("close", () => unsubscribe());
  websocket.once("error", () => unsubscribe());
}

function offersEventsProtocol(request: IncomingMessage): boolean {
  const value = request.headers["sec-websocket-protocol"];
  const header = Array.isArray(value) ? value.join(",") : value;
  return header?.split(",").some((protocol) => protocol.trim() === EVENTS_PROTOCOL) ?? false;
}

function offersTerminalProtocol(request: IncomingMessage): boolean {
  const value = request.headers["sec-websocket-protocol"];
  const header = Array.isArray(value) ? value.join(",") : value;
  return (
    header?.split(",").some((protocol) => [TERMINAL_PROTOCOL, TERMINAL_PROTOCOL_V2].includes(protocol.trim())) ?? false
  );
}
