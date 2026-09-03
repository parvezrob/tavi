import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import * as pty from "node-pty";
import { WebSocketServer, type WebSocket } from "ws";
import { AgentKindDetector } from "./agent-kinds.js";
import { AttachmentStore } from "./attachment.js";
import type { AttentionOverlay } from "./attention.js";
import { bearerToken, isAuthorized } from "./auth.js";
import type { HostConfig } from "./config.js";
import type { GhRunner } from "./gh.js";
import { configureGh } from "./gh.js";
import type { PullRequestLookup } from "./git.js";
import type { HerdrAgentSource } from "./herdr.js";
import type { AgentEventSource } from "./herdr-events.js";
import { type Route, type RouteContext, sendJson } from "./http.js";
import { log } from "./log.js";
import { DeviceRegistry, PairingSessions } from "./pairing.js";
import { PreviewRegistry, type DiscoveryDeps } from "./preview.js";
import { ProjectHistory } from "./projects.js";
import { EVENTS_PROTOCOL, TERMINAL_PROTOCOL, TERMINAL_PROTOCOL_V2 } from "./protocol.js";
import { agentRoutes } from "./routes/agents.js";
import { deviceRoutes } from "./routes/devices.js";
import { fileRoutes } from "./routes/files.js";
import { healthRoutes } from "./routes/health.js";
import { herdrRoutes } from "./routes/herdr.js";
import { hostRoutes } from "./routes/host.js";
import { pairingRoutes, publicPairingRoutes } from "./routes/pairing.js";
import { previewRoutes } from "./routes/preview.js";
import { sourceControlRoutes } from "./routes/source-control.js";
import { configureTailscale, type TailscaleRunner } from "./tailscale.js";
import {
  bridgeTerminal,
  bridgeTerminalV2,
  parseResumeRequest,
  sendTerminal,
  spawnAttachmentTerminal,
  type TerminalResumeRequest,
  type TerminalTarget,
} from "./terminal-bridge.js";
import type { WorkspaceInfo } from "./types.js";
import { InputError, safeSessionId } from "./validation.js";
import { scanWorkspaces } from "./workspaces.js";

export interface TaviServerOptions {
  config: HostConfig;
  herdr?: HerdrAgentSource;
  // The folder scan behind `/api/projects`; injectable so tests need no
  // real directory tree.
  listWorkspaces?: (roots: string[]) => Promise<WorkspaceInfo[]>;
  agentEvents?: AgentEventSource;
  attention?: AttentionOverlay;
  projects?: ProjectHistory;
  agentKinds?: AgentKindDetector;
  devices?: DeviceRegistry;
  // The pull-request lookup behind /api/repos; injectable so tests never
  // run the developer's gh (#74 review).
  pullRequests?: PullRequestLookup;
  // The `gh` runner behind the pull-request routes (#79); injectable for
  // the same reason. The default finds gh on the login-shell PATH.
  gh?: GhRunner;
  // `tailscale status --json` behind the caller's path on /api/host (#86);
  // injectable so tests never ask the developer's tailnet.
  tailscale?: TailscaleRunner;
  pairing?: PairingSessions;
  spawnTerminal?: typeof pty.spawn;
  /** Checks npm for a newer host and applies it (the managed runtime's self-update). */
  update?: () => Promise<unknown>;
  attachmentRetentionMs?: number;
  attachmentBufferBytes?: number;
  // Dev-server preview (#58): the tickets the door honours, whether Tailscale
  // Serve publishes the door, and how dev servers are found. All injectable.
  previews?: PreviewRegistry;
  doorReady?: () => Promise<boolean>;
  discovery?: DiscoveryDeps & { kill?: (pid: number) => void };
  // How often an open WebSocket re-checks that its credential still exists,
  // so `tavi devices revoke` cuts a live phone off, not just its next call.
  authorizationRecheckMs?: number;
}

export async function createTaviServer(options: TaviServerOptions) {
  const {
    config,
    herdr,
    listWorkspaces = scanWorkspaces,
    agentEvents,
    attention,
    projects = new ProjectHistory(config.stateDir),
    agentKinds = new AgentKindDetector({ shell: config.shell }),
    devices = new DeviceRegistry(config.stateDir),
    pairing = new PairingSessions(),
    spawnTerminal = pty.spawn,
    update,
    previews = new PreviewRegistry(),
    doorReady = async () => false,
    discovery,
    pullRequests,
    gh,
    tailscale,
  } = options;
  configureGh(config.shell);
  configureTailscale(config.shell);
  previews.start();
  const eventsWss = new WebSocketServer({
    noServer: true,
    handleProtocols(protocols) {
      return protocols.has(EVENTS_PROTOCOL) ? EVENTS_PROTOCOL : false;
    },
  });
  agentEvents?.start();
  const attachments = new AttachmentStore({
    retentionMs: options.attachmentRetentionMs,
    maxBufferBytes: options.attachmentBufferBytes,
  });
  const wss = new WebSocketServer({
    noServer: true,
    handleProtocols(protocols) {
      if (protocols.has(TERMINAL_PROTOCOL_V2)) return TERMINAL_PROTOCOL_V2;
      return protocols.has(TERMINAL_PROTOCOL) ? TERMINAL_PROTOCOL : false;
    },
  });

  // One rule for HTTP and WebSocket alike: the host's own token (the CLI and
  // pre-pairing dev flow) or any paired phone's credential (#46).
  const credentialAuthorized = (token: string | undefined): boolean =>
    isAuthorized(token, config.token) || devices.authorize(token ?? "") !== undefined;
  const authorized = (request: IncomingMessage): boolean => credentialAuthorized(bearerToken(request));
  const recheckMs = options.authorizationRecheckMs ?? 2_000;
  // A revoked phone may hold an events stream or a terminal open for hours;
  // re-check its credential on a short clock and close with a code the app
  // can tell apart from a network drop.
  const keepAuthorized = (websocket: WebSocket, request: IncomingMessage): void => {
    const token = bearerToken(request);
    const timer = setInterval(() => {
      if (credentialAuthorized(token)) return;
      clearInterval(timer);
      websocket.close(4401, "credential revoked");
    }, recheckMs);
    timer.unref?.();
    websocket.once("close", () => clearInterval(timer));
  };

  const server = createServer(async (request, response) => {
    try {
      await routeRequest(request, response, {
        config,
        herdr,
        listWorkspaces,
        attention,
        update,
        projects,
        agentKinds,
        devices,
        pairing,
        authorized,
        previews,
        doorReady,
        discovery,
        pullRequests,
        gh,
        tailscale,
      });
    } catch (error) {
      const status = error instanceof InputError ? 400 : 500;
      const message = error instanceof Error ? error.message : "Unexpected server error.";
      // The body says only that something failed; the stack belongs on the log.
      if (status === 500) log.error("http", message, { error });
      sendJson(response, status, { error: message });
    }
  });

  server.on("upgrade", async (request, socket, head) => {
    try {
      const url = new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);
      if (url.pathname === "/api/events") {
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
          serveAgentEvents(websocket, agentEvents);
        });
        return;
      }

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

      // Herdr agents are terminal targets only when Herdr itself confirms
      // them; a down Herdr degrades honestly instead of guessing.
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
        spawn: () => spawnAttachmentTerminal(herdr.attachCommand(paneId), config, spawnTerminal),
        detachedSize: () => herdr.paneSize?.(paneId) ?? Promise.resolve(undefined),
      };

      const resume = parseResumeRequest(url);
      wss.handleUpgrade(request, socket, head, (websocket) => {
        keepAuthorized(websocket, request);
        wss.emit("connection", websocket, request, target, resume);
      });
    } catch {
      socket.destroy();
    }
  });

  wss.on(
    "connection",
    (websocket: WebSocket, _request: IncomingMessage, target: TerminalTarget, resume?: TerminalResumeRequest) => {
      try {
        if (websocket.protocol === TERMINAL_PROTOCOL_V2) {
          bridgeTerminalV2(websocket, target, attachments, resume);
        } else {
          bridgeTerminal(websocket, target);
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : "Could not open the terminal.";
        sendTerminal(websocket, { type: "error", message });
        websocket.close(1011, "terminal unavailable");
      }
    },
  );

  server.on("close", () => {
    attachments.disposeAll();
    agentEvents?.stop();
    previews.stop();
  });

  // `http.Server.close` only stops accepting; it waits for every open
  // connection to end on its own, and upgraded WebSocket sockets are not even
  // tracked. A phone with the app open holds the events stream (and often a
  // terminal) for hours, so a plain close never finishes and launchd has to
  // wait out its kill timer while `launchctl bootout` reports success (#21).
  // Tell every client the host is restarting and drop the connections so the
  // process exits promptly.
  const closeServer = server.close.bind(server);
  server.close = (callback?: (error?: Error) => void) => {
    for (const websocket of eventsWss.clients) websocket.close(1001, "host restarting");
    for (const websocket of wss.clients) websocket.close(1001, "host restarting");
    server.closeAllConnections();
    return closeServer(callback);
  };
  return server;
}

// Snapshot-based push: the phone always receives the full agent list, so a
// missed frame can never leave a stale agent on screen.
function serveAgentEvents(websocket: WebSocket, agentEvents?: AgentEventSource): void {
  const send = (snapshot: { available: boolean; reason?: string; agents: unknown[] }) => {
    if (websocket.readyState !== websocket.OPEN) return;
    websocket.send(JSON.stringify({ type: "agents", ...snapshot }));
  };

  if (!agentEvents) {
    send({
      available: false,
      reason: "Herdr integration is not configured on this host.",
      agents: [],
    });
    return;
  }

  const unsubscribe = agentEvents.subscribe(send);
  if (!agentEvents.latest) {
    send({ available: false, reason: "Waiting for the first Herdr snapshot.", agents: [] });
  }
  websocket.once("close", unsubscribe);
  websocket.once("error", unsubscribe);
}

function offersEventsProtocol(request: IncomingMessage): boolean {
  const value = request.headers["sec-websocket-protocol"];
  const header = Array.isArray(value) ? value.join(",") : value;
  return header?.split(",").some((protocol) => protocol.trim() === EVENTS_PROTOCOL) ?? false;
}

const PUBLIC_ROUTES: Route[] = [healthRoutes, publicPairingRoutes];

const ROUTES: Route[] = [
  deviceRoutes,
  pairingRoutes,
  hostRoutes,
  agentRoutes,
  herdrRoutes,
  sourceControlRoutes,
  fileRoutes,
  previewRoutes,
];

async function routeRequest(request: IncomingMessage, response: ServerResponse, context: RouteContext): Promise<void> {
  const url = new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);
  for (const route of PUBLIC_ROUTES) {
    if (await route(url, request, response, context)) return;
  }

  if (url.pathname.startsWith("/api/") && !context.authorized(request)) {
    sendJson(response, 401, { error: "Invalid access token." });
    return;
  }

  for (const route of ROUTES) {
    if (await route(url, request, response, context)) return;
  }

  sendJson(response, 404, { error: "Not found." });
}

function offersTerminalProtocol(request: IncomingMessage): boolean {
  const value = request.headers["sec-websocket-protocol"];
  const header = Array.isArray(value) ? value.join(",") : value;
  return (
    header?.split(",").some((protocol) => [TERMINAL_PROTOCOL, TERMINAL_PROTOCOL_V2].includes(protocol.trim())) ?? false
  );
}
