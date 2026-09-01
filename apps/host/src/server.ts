import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { arch, platform } from "node:os";
import * as pty from "node-pty";
import { WebSocketServer, type RawData, type WebSocket } from "ws";
import { bearerToken, isAuthorized } from "./auth.js";
import { DeviceRegistry, PairingSessions } from "./pairing.js";
import type { HostConfig } from "./config.js";
import { VERSION } from "./config.js";
import { AttachmentStore, type TerminalAttachment, type AttachmentClient } from "./attachment.js";
import { AGENT_KIND_NAMES, AgentKindDetector, SHELL_KIND } from "./agent-kinds.js";
import { parseClaudeHookEvent, type AttentionOverlay } from "./attention.js";
import type { AgentEventSource } from "./herdr-events.js";
import {
  EVENTS_PROTOCOL,
  MAX_OUTPUT_PAYLOAD_BYTES,
  MAX_TERMINAL_FRAME_BYTES,
  chunkTerminalOutput,
  encodeOutputFrame,
  parseClientTerminalMessage,
  TERMINAL_PROTOCOL,
  TERMINAL_PROTOCOL_V2,
} from "./protocol.js";
import type { DialogDecision, HerdrAgentSource, TerminalSize } from "./herdr.js";
import {
  isWithinRoots,
  mergeRecentProjects,
  normalizeProjectPath,
  ProjectHistory,
} from "./projects.js";
import type { AttachCommand, HostInfo, ServerTerminalMessage, WorkspaceInfo } from "./types.js";
import { InputError, safeSessionId } from "./validation.js";
import { scanWorkspaces } from "./workspaces.js";

const MAX_BODY_BYTES = 64 * 1024;
const MAX_PREVIEW_CHARACTERS = 4_096;
const MAX_PROMPT_CHARACTERS = 16_384;
// Small buffers on purpose: when the phone falls behind, pausing the pty
// quickly means the pane holds fresh frames instead of the connection
// replaying a large backlog of stale screen paints.
const WEBSOCKET_HIGH_WATER_BYTES = 64 * 1024;
const WEBSOCKET_LOW_WATER_BYTES = 16 * 1024;
const MAX_PENDING_OUTPUT_BYTES = 256 * 1024;
const BACKPRESSURE_POLL_MILLISECONDS = 25;

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
  pairing?: PairingSessions;
  spawnTerminal?: typeof pty.spawn;
  /** Checks npm for a newer host and applies it (the managed runtime's self-update). */
  update?: () => Promise<unknown>;
  attachmentRetentionMs?: number;
  attachmentBufferBytes?: number;
  // How often an open WebSocket re-checks that its credential still exists,
  // so `tavi devices revoke` cuts a live phone off, not just its next call.
  authorizationRecheckMs?: number;
}

interface TerminalResumeRequest {
  stream: string;
  offset: number;
}

interface TerminalTarget {
  key: string;
  spawn: () => pty.IPty;
  // What the desktop shows for this pane; handed back on phone detach (#44).
  detachedSize?: () => Promise<TerminalSize | undefined>;
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
  } = options;
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
      });
    } catch (error) {
      const status = error instanceof InputError ? 400 : 500;
      const message = error instanceof Error ? error.message : "Unexpected server error.";
      if (status === 500) console.error(error);
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
      const lookup = await herdr.findAgent(paneId);
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

function parseResumeRequest(url: URL): TerminalResumeRequest | undefined {
  const stream = url.searchParams.get("stream");
  const resume = url.searchParams.get("resume");
  if (!stream || !resume) return undefined;
  if (!/^[A-Za-z0-9-]{1,64}$/.test(stream) || !/^\d{1,15}$/.test(resume)) return undefined;
  return { stream, offset: Number.parseInt(resume, 10) };
}

interface RouteContext {
  config: HostConfig;
  listWorkspaces: (roots: string[]) => Promise<WorkspaceInfo[]>;
  projects: ProjectHistory;
  agentKinds: AgentKindDetector;
  devices: DeviceRegistry;
  pairing: PairingSessions;
  authorized: (request: IncomingMessage) => boolean;
  herdr?: HerdrAgentSource | undefined;
  attention?: AttentionOverlay | undefined;
  update?: (() => Promise<unknown>) | undefined;
}

async function routeRequest(
  request: IncomingMessage,
  response: ServerResponse,
  context: RouteContext,
): Promise<void> {
  const { config, herdr, listWorkspaces, attention, projects, agentKinds, devices, pairing, authorized, update } = context;
  const url = new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);

  if (url.pathname === "/api/health" && request.method === "GET") {
    sendJson(response, 200, { ok: true, version: VERSION });
    return;
  }

  // The one unauthenticated write: redeeming a pairing secret (#45). The
  // secret is single-use, 128-bit, and dies in five minutes; the phone gets
  // its own credential back and the host's token never leaves the Mac.
  if (url.pathname === "/api/pair" && request.method === "POST") {
    const body = await readJsonBody(request);
    const record = typeof body === "object" && body !== null ? (body as Record<string, unknown>) : {};
    const secret = typeof record.secret === "string" ? record.secret : "";
    const deviceName = typeof record.deviceName === "string" ? record.deviceName : "";
    if (!pairing.redeem(secret)) {
      sendJson(response, 401, { error: "That pairing code is not valid any more. Run `tavi pair` on the Mac for a fresh one." });
      return;
    }
    const { device, credential } = devices.add(deviceName);
    sendJson(response, 201, {
      credential,
      device,
      host: { name: config.machineName, fingerprint: devices.identity().fingerprint },
    });
    return;
  }

  if (url.pathname.startsWith("/api/") && !authorized(request)) {
    sendJson(response, 401, { error: "Invalid access token." });
    return;
  }

  // Paired-device management (#46). Listing and revoking others is the host
  // owner's act; a phone may only unpair itself.
  if (url.pathname === "/api/devices" && request.method === "GET") {
    if (!isAuthorized(bearerToken(request), config.token)) {
      sendJson(response, 403, { error: "Only the host itself can list paired devices." });
      return;
    }
    sendJson(response, 200, { devices: devices.list() });
    return;
  }
  if (url.pathname === "/api/devices/me" && request.method === "DELETE") {
    const me = devices.authorize(bearerToken(request) ?? "");
    if (!me) {
      sendJson(response, 400, { error: "Only a paired phone can unpair itself." });
      return;
    }
    devices.revoke(me.id);
    response.writeHead(204).end();
    return;
  }
  const deviceMatch = url.pathname.match(/^\/api\/devices\/([^/]+)$/);
  if (deviceMatch && request.method === "DELETE") {
    if (!isAuthorized(bearerToken(request), config.token)) {
      sendJson(response, 403, { error: "Only the host itself can revoke a device." });
      return;
    }
    if (!devices.revoke(safeSessionId(deviceMatch[1] || ""))) {
      sendJson(response, 404, { error: "No paired device with that id." });
      return;
    }
    response.writeHead(204).end();
    return;
  }

  // Minting a pairing code is the host owner's act: only the host token may,
  // never an already-paired phone.
  if (url.pathname === "/api/pair/begin" && request.method === "POST") {
    if (!isAuthorized(bearerToken(request), config.token)) {
      sendJson(response, 403, { error: "Only the host itself can start pairing." });
      return;
    }
    try {
      const { secret, expiresAt } = pairing.begin();
      sendJson(response, 201, {
        secret,
        expiresAt,
        host: { name: config.machineName, fingerprint: devices.identity().fingerprint },
      });
    } catch (error) {
      sendJson(response, 429, { error: error instanceof Error ? error.message : "Could not start pairing." });
    }
    return;
  }

  if (url.pathname === "/api/host" && request.method === "GET") {
    const host: HostInfo = {
      name: config.machineName,
      platform: platform(),
      arch: arch(),
      version: VERSION,
    };
    sendJson(response, 200, { ...host, fingerprint: devices.identity().fingerprint });
    return;
  }

  // Everything the New Agent picker needs in one call (#24): the folders
  // agents are living in now plus this host's remembered choices, the
  // browsable roots, the roots themselves so the phone knows which custom
  // path will need the extra confirmation, and which agent kinds this Mac
  // can actually launch.
  if (url.pathname === "/api/projects" && request.method === "GET") {
    const [agents, workspaces, kinds] = await Promise.all([
      herdr ? herdr.listAgents() : undefined,
      listWorkspaces(config.roots),
      agentKinds.list(),
    ]);
    const agentCwds = agents?.available ? agents.agents.map((agent) => agent.cwd) : [];
    sendJson(response, 200, {
      recent: mergeRecentProjects(projects.list(), agentCwds, config.roots),
      workspaces,
      roots: config.roots,
      agents: kinds,
    });
    return;
  }

  const previewMatch = url.pathname.match(/^\/api\/agents\/([^/]+)\/preview$/);
  if (previewMatch && request.method === "GET") {
    if (!herdr) {
      sendJson(response, 404, { error: "Herdr integration is not configured on this host." });
      return;
    }
    const paneId = safeSessionId(previewMatch[1] || "");
    const requestedLines = Number.parseInt(url.searchParams.get("lines") || "12", 10);
    const lines = Number.isFinite(requestedLines) ? clamp(requestedLines, 1, 50) : 12;
    const result = await herdr.readAgent(paneId, lines);
    if (!result.available) {
      sendJson(response, 503, { error: result.reason });
      return;
    }
    sendJson(response, 200, {
      paneId,
      lines,
      preview: result.preview.slice(0, MAX_PREVIEW_CHARACTERS),
    });
    return;
  }

  const dialogMatch = url.pathname.match(/^\/api\/agents\/([^/]+)\/dialog$/);
  if (dialogMatch && request.method === "GET") {
    if (!herdr) {
      sendJson(response, 404, { error: "Herdr integration is not configured on this host." });
      return;
    }
    const paneId = safeSessionId(dialogMatch[1] || "");
    const result = await herdr.readDialog(paneId);
    if ("available" in result) {
      sendJson(response, 503, { error: result.reason });
      return;
    }
    sendJson(response, 200, {
      paneId,
      present: result.present,
      ...(result.present ? { dialog: result.dialog } : {}),
    });
    return;
  }

  const decisionMatch = url.pathname.match(/^\/api\/agents\/([^/]+)\/decision$/);
  if (decisionMatch && request.method === "POST") {
    if (!herdr) {
      sendJson(response, 404, { error: "Herdr integration is not configured on this host." });
      return;
    }
    const paneId = safeSessionId(decisionMatch[1] || "");
    const body = await readJsonBody(request);
    const record = typeof body === "object" && body !== null ? (body as Record<string, unknown>) : {};
    const rawDecision = record.decision;
    // "approve" / "deny", or { decision: "option", option: N } to pick a
    // specific numbered choice.
    let decision: DialogDecision | undefined;
    if (rawDecision === "approve" || rawDecision === "deny") {
      decision = rawDecision;
    } else if (rawDecision === "option") {
      const option = record.option;
      if (typeof option === "number" && Number.isInteger(option) && option > 0) {
        decision = { option };
      }
    }
    if (!decision) {
      sendJson(response, 400, {
        error: 'decision must be "approve", "deny", or "option" with a positive integer option.',
      });
      return;
    }
    // Trust gate, two layers. Outer (here): at least one authority must flag
    // this agent as waiting — the Claude hook overlay (Claude's own fact) or
    // herdr's live screen status. Inner (herdr.decideAgent): the pane is
    // re-read immediately before any key is sent and a real permission dialog
    // must still parse out of it, or nothing fires. The inner re-read is what
    // actually guarantees we never answer a stale card, so the outer layer is
    // a cheap "is this plausibly waiting" check, not the safety — which is why
    // it accepts either authority (some dialogs, e.g. the trust-folder prompt,
    // are herdr-blocked but never emit a PermissionRequest hook).
    const lookup = await herdr.findAgent(paneId);
    if (!lookup.available) {
      sendJson(response, 503, { error: lookup.reason });
      return;
    }
    const overlayBlocked = attention?.isBlocked(lookup.agent?.sessionRef) ?? false;
    const herdrBlocked = lookup.agent?.status === "blocked";
    if (!overlayBlocked && !herdrBlocked) {
      sendJson(response, 409, {
        error: "This agent is not waiting for a decision right now.",
        stale: true,
      });
      return;
    }
    const result = await herdr.decideAgent(paneId, decision);
    if (!result.decided) {
      sendJson(response, result.stale ? 409 : 503, {
        error: result.reason,
        ...(result.stale ? { stale: true } : {}),
      });
      return;
    }
    sendJson(response, 200, { decided: true, sent: result.sent, paneId });
    return;
  }

  const promptMatch = url.pathname.match(/^\/api\/agents\/([^/]+)\/prompt$/);
  if (promptMatch && request.method === "POST") {
    if (!herdr) {
      sendJson(response, 404, { error: "Herdr integration is not configured on this host." });
      return;
    }
    const paneId = safeSessionId(promptMatch[1] || "");
    const body = await readJsonBody(request);
    const text =
      typeof body === "object" && body !== null && "text" in body && typeof body.text === "string"
        ? body.text
        : undefined;
    if (!text || text.length > MAX_PROMPT_CHARACTERS) {
      sendJson(response, 400, { error: "Prompt text is required and must stay under the size limit." });
      return;
    }
    const result = await herdr.promptAgent(paneId, text);
    if (!result.submitted) {
      sendJson(response, 503, { error: result.reason });
      return;
    }
    sendJson(response, 202, { submitted: true, paneId });
    return;
  }

  if (url.pathname === "/api/herdr/tree" && request.method === "GET") {
    if (!herdr) {
      sendJson(response, 404, { error: "Herdr integration is not configured on this host." });
      return;
    }
    const tree = await herdr.listTree();
    if (!tree.available) {
      sendJson(response, 503, { error: tree.reason });
      return;
    }
    sendJson(response, 200, { workspaces: tree.workspaces });
    return;
  }

  const tabCloseMatch = url.pathname.match(/^\/api\/herdr\/tabs\/([^/]+)$/);
  if (tabCloseMatch && request.method === "DELETE") {
    if (!herdr) {
      sendJson(response, 404, { error: "Herdr integration is not configured on this host." });
      return;
    }
    const tabId = safeSessionId(tabCloseMatch[1] || "");
    const result = await herdr.closeTab(tabId);
    if (!result.closed) {
      sendJson(response, 503, { error: result.reason });
      return;
    }
    sendJson(response, 200, { closed: true, tabId });
    return;
  }

  // Rename a tab (#55): the user's own name for the task becomes the
  // pane's identity on the phone. Herdr owns the truth; the new label
  // reaches every phone through the events feed's refresh.
  if (tabCloseMatch && request.method === "PATCH") {
    if (!herdr) {
      sendJson(response, 404, { error: "Herdr integration is not configured on this host." });
      return;
    }
    const tabId = safeSessionId(tabCloseMatch[1] || "");
    const body = await readJsonBody(request);
    const record = typeof body === "object" && body !== null ? (body as Record<string, unknown>) : {};
    const label = typeof record.label === "string" ? record.label.trim() : "";
    if (!label || label.length > 120) {
      sendJson(response, 400, { error: "label must be 1–120 characters." });
      return;
    }
    const result = await herdr.renameTab(tabId, label);
    if (!result.renamed) {
      sendJson(response, 503, { error: result.reason });
      return;
    }
    sendJson(response, 200, { renamed: true, tabId, label: result.label });
    return;
  }

  if (url.pathname === "/api/herdr/tabs" && request.method === "POST") {
    if (!herdr) {
      sendJson(response, 404, { error: "Herdr integration is not configured on this host." });
      return;
    }
    const body = await readJsonBody(request);
    const record = typeof body === "object" && body !== null ? (body as Record<string, unknown>) : {};
    const agent = typeof record.agent === "string" ? record.agent : undefined;
    if (agent !== undefined && !AGENT_KIND_NAMES.includes(agent)) {
      sendJson(response, 400, { error: `agent must be one of: ${AGENT_KIND_NAMES.join(", ")}.` });
      return;
    }
    // herdr accepts a kind that is not installed and hands back a tab whose
    // launch has already failed — a dead pane that lists as nothing. Refuse
    // up front instead, with the reason the picker already shows.
    if (agent !== undefined) {
      const kind = (await agentKinds.list()).find((entry) => entry.kind === agent);
      if (kind && !kind.installed) {
        sendJson(response, 400, { error: `${kind.label} is not installed on this Mac.` });
        return;
      }
    }
    // `cwd` is required (#24). It used to be optional, which is exactly how
    // phone-created agents ended up in the host user's home directory.
    if (typeof record.cwd !== "string") {
      sendJson(response, 400, { error: "cwd is required: choose the project folder to work in." });
      return;
    }
    const candidate = normalizeProjectPath(record.cwd);
    if (!candidate.ok) {
      sendJson(response, 400, { error: candidate.reason });
      return;
    }
    // Outside the configured roots the phone must say so explicitly, which
    // it only does after asking the person a second time.
    if (!isWithinRoots(candidate.path, config.roots) && record.allowOutsideRoots !== true) {
      sendJson(response, 400, {
        error: "That folder is outside your project roots. Confirm the custom location to continue.",
        outsideRoots: true,
      });
      return;
    }
    const result = await herdr.createTab({
      agent,
      cwd: candidate.path,
      label: agent === SHELL_KIND ? "tavi terminal" : agent ? `tavi ${agent}` : "tavi",
    });
    if (!result.created) {
      sendJson(response, 503, { error: result.reason });
      return;
    }
    // Only a folder that actually launched something earns a place in the
    // picker's recent list.
    projects.remember(candidate.path);
    sendJson(response, 201, { paneId: result.paneId, tabId: result.tabId });
    return;
  }

  if (url.pathname === "/api/update" && request.method === "POST") {
    const outcome = update ? await update() : { status: "skipped", reason: "this host does not manage its own updates" };
    sendJson(response, 200, outcome);
    return;
  }

  if (url.pathname === "/api/hooks/claude" && request.method === "POST") {
    const event = parseClaudeHookEvent(await readJsonBody(request));
    if (!event) {
      sendJson(response, 400, { error: "A hook event needs hook_event_name and session_id." });
      return;
    }
    attention?.report(event);
    sendJson(response, 200, { ok: true });
    return;
  }

  if (url.pathname === "/api/agents" && request.method === "GET") {
    if (!herdr) {
      sendJson(response, 200, {
        provider: "herdr",
        available: false,
        reason: "Herdr integration is not configured on this host.",
        agents: [],
      });
      return;
    }
    const result = await herdr.listAgents();
    if (result.available && attention) {
      sendJson(response, 200, {
        ...result,
        agents: result.agents.map((agent) =>
          attention.isBlocked(agent.sessionRef)
            ? { ...agent, status: "blocked", authority: "claude-hook" }
            : agent,
        ),
      });
      return;
    }
    sendJson(response, 200, result);
    return;
  }

  if (url.pathname.startsWith("/api/")) {
    sendJson(response, 404, { error: "Not found." });
    return;
  }

  sendJson(response, 404, { error: "Not found." });
}

function spawnAttachmentTerminal(
  attach: AttachCommand,
  config: HostConfig,
  spawnTerminal: typeof pty.spawn,
): pty.IPty {
  const env = { ...process.env };
  delete env.npm_config_prefix;
  delete env.NPM_CONFIG_PREFIX;
  // Flow control stays off so a stray XOFF (Ctrl-S) can never freeze output.
  return spawnTerminal(attach.bin, attach.args, {
    name: "xterm-256color",
    cols: 100,
    rows: 30,
    cwd: config.stateDir,
    env: {
      ...env,
      TERM: "xterm-256color",
      COLORTERM: "truecolor",
    },
  });
}

function bridgeTerminalV2(
  websocket: WebSocket,
  target: TerminalTarget,
  attachments: AttachmentStore,
  resume?: TerminalResumeRequest,
): void {
  let attachment = attachments.get(target.key);
  let cursor: number;
  let resumed = false;

  if (
    attachment &&
    !attachment.hasExited &&
    resume &&
    resume.stream === attachment.stream &&
    attachment.contains(resume.offset)
  ) {
    cursor = resume.offset;
    resumed = true;
  } else {
    // A resume miss (no attachment, epoch mismatch, or the offset already
    // trimmed out of the ring) gets a fresh attach: herdr repaints the whole
    // pane, so the client is complete again without replay.
    attachment?.dispose();
    attachment = attachments.create(target.key, target.spawn(), {
      detachedSize: target.detachedSize,
    });
    cursor = attachment.endOffset;
  }
  const active = attachment;

  let flushTimer: NodeJS.Timeout | undefined;
  const clearFlushTimer = () => {
    if (flushTimer) clearInterval(flushTimer);
    flushTimer = undefined;
  };
  const flush = () => {
    while (
      websocket.readyState === websocket.OPEN &&
      cursor < active.endOffset &&
      websocket.bufferedAmount <= WEBSOCKET_HIGH_WATER_BYTES
    ) {
      const payload = active.read(cursor, MAX_OUTPUT_PAYLOAD_BYTES);
      if (payload === undefined) {
        // The client fell more than the resume buffer behind; a fresh attach
        // with a full redraw beats replaying that much stale screen paint.
        sendTerminal(websocket, {
          type: "error",
          message: "Terminal output overran the resume buffer.",
        });
        websocket.close(1011, "resume buffer overrun");
        return;
      }
      if (payload.length === 0) return;
      websocket.send(encodeOutputFrame(cursor, payload));
      cursor += payload.length;
    }
    if (cursor < active.endOffset && websocket.readyState === websocket.OPEN) {
      if (flushTimer) return;
      flushTimer = setInterval(() => {
        if (websocket.readyState !== websocket.OPEN) {
          clearFlushTimer();
          return;
        }
        if (websocket.bufferedAmount > WEBSOCKET_LOW_WATER_BYTES) return;
        clearFlushTimer();
        flush();
      }, BACKPRESSURE_POLL_MILLISECONDS);
    } else {
      clearFlushTimer();
    }
  };

  const client: AttachmentClient = {
    onOutput: flush,
    onExit: (exit) => {
      clearFlushTimer();
      sendTerminal(websocket, {
        type: "exit",
        code: exit.code,
        ...(typeof exit.signal === "number" ? { signal: exit.signal } : {}),
      });
      websocket.close(1000, "terminal exited");
    },
    onSuperseded: () => {
      clearFlushTimer();
      sendTerminal(websocket, { type: "error", message: "Another connection took over this terminal." });
      websocket.close(1000, "superseded");
    },
  };

  active.claim(client);
  sendTerminal(websocket, { type: "ready", stream: active.stream, offset: cursor, resumed });
  flush();

  websocket.on("message", (raw: RawData, isBinary: boolean) => {
    if (isBinary) {
      sendTerminal(websocket, { type: "error", message: "Binary terminal messages are unsupported." });
      websocket.close(1003, "text frames required");
      return;
    }
    if (Buffer.byteLength(raw.toString()) > MAX_TERMINAL_FRAME_BYTES) {
      sendTerminal(websocket, { type: "error", message: "Terminal message is too large." });
      websocket.close(1009, "message too large");
      return;
    }
    try {
      const message = parseClientTerminalMessage(JSON.parse(raw.toString()));
      if (!message) {
        sendTerminal(websocket, { type: "error", message: "Invalid terminal message." });
        return;
      }
      switch (message.type) {
        case "input":
          active.write(message.data);
          break;
        case "resize":
          active.resize(clamp(message.cols, 20, 400), clamp(message.rows, 5, 200));
          break;
        case "ping":
          sendTerminal(websocket, { type: "pong", id: message.id });
          break;
      }
    } catch {
      sendTerminal(websocket, { type: "error", message: "Invalid terminal message." });
    }
  });

  const releaseClient = () => {
    clearFlushTimer();
    active.release(client);
  };
  websocket.once("close", releaseClient);
  websocket.once("error", releaseClient);
}

function bridgeTerminal(websocket: WebSocket, target: TerminalTarget): void {
  const terminal = target.spawn();

  let attachmentClosed = false;
  let terminalPaused = false;
  let pendingOutputBytes = 0;
  let backpressureTimer: NodeJS.Timeout | undefined;
  const pendingOutputChunks: string[] = [];

  const clearBackpressureTimer = () => {
    if (backpressureTimer) clearInterval(backpressureTimer);
    backpressureTimer = undefined;
  };
  const killAttachment = () => {
    clearBackpressureTimer();
    if (attachmentClosed) return;
    attachmentClosed = true;
    terminal.kill();
  };
  const pauseTerminal = () => {
    if (!terminalPaused) terminal.pause();
    terminalPaused = true;
    if (backpressureTimer) return;
    backpressureTimer = setInterval(() => {
      if (websocket.readyState !== websocket.OPEN) {
        clearBackpressureTimer();
        return;
      }
      if (websocket.bufferedAmount > WEBSOCKET_LOW_WATER_BYTES) return;
      flushOutput();
      if (pendingOutputChunks.length === 0 && websocket.bufferedAmount <= WEBSOCKET_LOW_WATER_BYTES) {
        terminal.resume();
        terminalPaused = false;
        clearBackpressureTimer();
      }
    }, BACKPRESSURE_POLL_MILLISECONDS);
  };
  const flushOutput = () => {
    while (
      pendingOutputChunks.length > 0 &&
      websocket.readyState === websocket.OPEN &&
      websocket.bufferedAmount <= WEBSOCKET_HIGH_WATER_BYTES
    ) {
      const chunk = pendingOutputChunks.shift();
      if (chunk === undefined) break;
      pendingOutputBytes -= Buffer.byteLength(chunk);
      if (!sendTerminal(websocket, { type: "output", data: chunk })) break;
    }
    if (pendingOutputChunks.length > 0 || websocket.bufferedAmount > WEBSOCKET_HIGH_WATER_BYTES) {
      pauseTerminal();
    }
  };

  sendTerminal(websocket, { type: "ready" });
  terminal.onData((data) => {
    const dataBytes = Buffer.byteLength(data);
    if (dataBytes > MAX_PENDING_OUTPUT_BYTES - pendingOutputBytes) {
      sendTerminal(websocket, {
        type: "error",
        message: "Terminal output exceeded the connection safety buffer.",
      });
      websocket.close(1013, "terminal output overloaded");
      killAttachment();
      return;
    }
    pendingOutputChunks.push(...chunkTerminalOutput(data));
    pendingOutputBytes += dataBytes;
    flushOutput();
  });
  terminal.onExit(({ exitCode, signal }) => {
    if (attachmentClosed) return;
    attachmentClosed = true;
    clearBackpressureTimer();
    sendTerminal(websocket, {
      type: "exit",
      code: exitCode,
      ...(typeof signal === "number" ? { signal } : {}),
    });
    websocket.close(1000, "terminal exited");
  });

  websocket.on("message", (raw: RawData, isBinary: boolean) => {
    if (isBinary) {
      sendTerminal(websocket, { type: "error", message: "Binary terminal messages are unsupported." });
      websocket.close(1003, "text frames required");
      return;
    }
    if (Buffer.byteLength(raw.toString()) > MAX_TERMINAL_FRAME_BYTES) {
      sendTerminal(websocket, { type: "error", message: "Terminal message is too large." });
      websocket.close(1009, "message too large");
      return;
    }
    try {
      const message = parseClientTerminalMessage(JSON.parse(raw.toString()));
      if (!message) {
        sendTerminal(websocket, { type: "error", message: "Invalid terminal message." });
        return;
      }
      switch (message.type) {
        case "input":
          terminal.write(message.data);
          break;
        case "resize":
          terminal.resize(clamp(message.cols, 20, 400), clamp(message.rows, 5, 200));
          break;
        case "ping":
          sendTerminal(websocket, { type: "pong", id: message.id });
          break;
      }
    } catch {
      sendTerminal(websocket, { type: "error", message: "Invalid terminal message." });
    }
  });

  websocket.once("close", killAttachment);
  websocket.once("error", killAttachment);
}

function sendTerminal(websocket: WebSocket, message: ServerTerminalMessage): boolean {
  if (websocket.readyState !== websocket.OPEN) return false;
  const frame = JSON.stringify(message);
  if (Buffer.byteLength(frame) > MAX_TERMINAL_FRAME_BYTES) {
    websocket.close(1011, "server frame too large");
    return false;
  }
  websocket.send(frame);
  return true;
}

async function readJsonBody(request: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buffer.length;
    if (size > MAX_BODY_BYTES) throw new InputError("Request body is too large.");
    chunks.push(buffer);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new InputError("Request body must be valid JSON.");
  }
}

function sendJson(response: ServerResponse, status: number, value: unknown): void {
  if (response.headersSent) return;
  const body = JSON.stringify(value);
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store",
  });
  response.end(body);
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function offersTerminalProtocol(request: IncomingMessage): boolean {
  const value = request.headers["sec-websocket-protocol"];
  const header = Array.isArray(value) ? value.join(",") : value;
  return (
    header
      ?.split(",")
      .some((protocol) => [TERMINAL_PROTOCOL, TERMINAL_PROTOCOL_V2].includes(protocol.trim())) ?? false
  );
}
