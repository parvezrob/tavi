import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import * as pty from "node-pty";
import { WebSocketServer, type WebSocket } from "ws";
import { AgentKindDetector } from "./agent-kinds.js";
import { AttachmentStore } from "./attachment.js";
import type { AttentionOverlay } from "./attention.js";
import { bearerToken, isAuthorized } from "./auth.js";
import type { Chaos } from "./chaos.js";
import type { HostConfig } from "./config.js";
import type { GhRunner } from "./gh.js";
import { configureGh } from "./gh.js";
import type { PullRequestLookup } from "./pull-request-cache.js";
import type { HerdrAgentSource } from "./herdr-types.js";
import type { AgentEventSource } from "./herdr-events.js";
import { type Route, type RouteContext, sendJson } from "./http.js";
import { log } from "./log.js";
import { DeviceRegistry, PairingSessions } from "./pairing.js";
import { PreviewRegistry } from "./preview.js";
import type { DiscoveryDeps } from "./preview-servers.js";
import { ProjectHistory } from "./projects.js";
import { EVENTS_PROTOCOL, MAX_TERMINAL_FRAME_BYTES, TERMINAL_PROTOCOL, TERMINAL_PROTOCOL_V2 } from "./protocol.js";
import { agentRoutes } from "./routes/agents.js";
import { chaosRoutes } from "./routes/chaos.js";
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
  credentialRevoked,
  hostClosing,
  socketCensus,
  socketClosed,
  type SocketKind,
  socketOpened,
} from "./socket-log.js";
import { upgradeEvents, upgradeTerminal } from "./websocket-upgrades.js";
import {
  bridgeTerminal,
  bridgeTerminalV2,
  sendTerminal,
  type TerminalResumeRequest,
  type TerminalTarget,
} from "./terminal-bridge.js";
import type { WorkspaceInfo } from "./types.js";
import { InputError } from "./validation.js";
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
  /** Fault injection (#111); present only under `TAVI_CHAOS=on`. */
  chaos?: Chaos;
}

// How often the census line may speak at all; it stays quiet unless the counts
// moved since the last one.
const CENSUS_INTERVAL_MS = 60_000;

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
    chaos,
  } = options;
  configureGh(config.shell);
  configureTailscale(config.shell);
  previews.start();
  const eventsWss = new WebSocketServer({
    noServer: true,
    // The events socket carries snapshots and control frames; a client frame
    // larger than a terminal's is a bug or an attack, and ws answers 1009
    // rather than buffering it (#111).
    maxPayload: MAX_TERMINAL_FRAME_BYTES,
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
  const keepAuthorized = (websocket: WebSocket, request: IncomingMessage, kind: SocketKind): void => {
    const token = bearerToken(request);
    // The device's public id, never its credential. The host's own token is a
    // person at a terminal, not a paired phone, and says so.
    const device = devices.authorize(token ?? "")?.id ?? (isAuthorized(token, config.token) ? "host-token" : "unknown");
    // No part of `request.url` goes to the log: the path is the phone's own
    // string, and `kind` already says which of the host's two routes answered.
    socketOpened(websocket, kind, { device, protocol: websocket.protocol });
    websocket.once("close", (code: number) => socketClosed(websocket, kind, code));
    const timer = setInterval(() => {
      if (credentialAuthorized(token)) return;
      clearInterval(timer);
      credentialRevoked(websocket, kind);
      // No gate may hold this one: a revoked phone reads 4401, not silence.
      chaos?.revoke(websocket);
      websocket.close(4401, "credential revoked");
    }, recheckMs);
    timer.unref?.();
    websocket.once("close", () => clearInterval(timer));
  };

  // The one recurring line, and it only speaks when the numbers changed —
  // enough to see a reconnect loop in the log without it becoming the log.
  const census = setInterval(() => socketCensus(eventsWss.clients.size, wss.clients.size), CENSUS_INTERVAL_MS);
  census.unref?.();

  const server = createServer(async (request, response) => {
    // `hostPause` (#111): the answer is withheld, not refused — the request
    // hangs until the client's own timeout ends it, and its socket with it.
    if (chaos?.hostPaused()) return;
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
        chaos,
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
    if (chaos?.hostPaused()) return;
    try {
      const url = new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);
      if (url.pathname === "/api/events") {
        upgradeEvents({ request, socket, head, eventsWss, authorized, keepAuthorized, agentEvents, chaos });
        return;
      }
      await upgradeTerminal({
        request,
        socket,
        head,
        url,
        wss,
        authorized,
        keepAuthorized,
        herdr,
        config,
        spawnTerminal,
      });
    } catch {
      // The socket is raw here: nothing can be said on it that a client
      // would parse, so an unexpected failure closes it and the phone
      // reconnects.
      socket.destroy();
    }
  });

  wss.on(
    "connection",
    (websocket: WebSocket, _request: IncomingMessage, target: TerminalTarget, resume?: TerminalResumeRequest) => {
      try {
        if (websocket.protocol === TERMINAL_PROTOCOL_V2) {
          bridgeTerminalV2(websocket, target, attachments, resume, chaos);
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
    clearInterval(census);
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
    for (const websocket of [...eventsWss.clients, ...wss.clients]) {
      hostClosing(websocket);
      websocket.close(1001, "host restarting");
    }
    server.closeAllConnections();
    return closeServer(callback);
  };
  return server;
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
  chaosRoutes,
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
