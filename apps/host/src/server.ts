import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { arch, platform } from "node:os";
import * as pty from "node-pty";
import { WebSocketServer, type RawData, type WebSocket } from "ws";
import { bearerToken, isAuthorized } from "./auth.js";
import type { HostConfig } from "./config.js";
import { VERSION } from "./config.js";
import { AttachmentStore, type TerminalAttachment, type AttachmentClient } from "./attachment.js";
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
import type { HerdrAgentSource } from "./herdr.js";
import type { AttachCommand, HostInfo, ServerTerminalMessage, SessionBackend } from "./types.js";
import { InputError, parseCreateSession, safeSessionId } from "./validation.js";

const MAX_BODY_BYTES = 64 * 1024;
const MAX_PREVIEW_CHARACTERS = 4_096;
const MAX_PROMPT_CHARACTERS = 16_384;
// Small buffers on purpose: when the phone falls behind, pausing the pty
// quickly means tmux holds fresh frames instead of the connection replaying a
// large backlog of stale screen paints.
const WEBSOCKET_HIGH_WATER_BYTES = 64 * 1024;
const WEBSOCKET_LOW_WATER_BYTES = 16 * 1024;
const MAX_PENDING_OUTPUT_BYTES = 256 * 1024;
const BACKPRESSURE_POLL_MILLISECONDS = 25;

export interface MochaServerOptions {
  config: HostConfig;
  tmux: SessionBackend;
  herdr?: HerdrAgentSource;
  agentEvents?: AgentEventSource;
  spawnTerminal?: typeof pty.spawn;
  attachmentRetentionMs?: number;
  attachmentBufferBytes?: number;
}

interface TerminalResumeRequest {
  stream: string;
  offset: number;
}

interface TerminalTarget {
  key: string;
  spawn: () => pty.IPty;
}

export async function createMochaServer(options: MochaServerOptions) {
  const { config, tmux, herdr, agentEvents, spawnTerminal = pty.spawn } = options;
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

  const server = createServer(async (request, response) => {
    setCors(request, response);
    if (request.method === "OPTIONS") {
      response.writeHead(204).end();
      return;
    }

    try {
      await routeRequest(request, response, config, tmux, herdr);
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
        if (!isAuthorized(bearerToken(request), config.token)) {
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
          serveAgentEvents(websocket, agentEvents);
        });
        return;
      }

      const sessionMatch = url.pathname.match(/^\/api\/sessions\/([^/]+)\/terminal$/);
      const agentMatch = url.pathname.match(/^\/api\/agents\/([^/]+)\/terminal$/);
      if ((!sessionMatch && !agentMatch) || !isAuthorized(bearerToken(request), config.token)) {
        socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }
      if (!offersTerminalProtocol(request)) {
        socket.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }

      let target: TerminalTarget;
      if (sessionMatch) {
        const id = safeSessionId(sessionMatch[1] || "");
        if (!(await tmux.getSession(id))) {
          socket.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
          socket.destroy();
          return;
        }
        target = {
          key: id,
          spawn: () => spawnAttachmentTerminal(tmux.attachCommand(id), config, spawnTerminal),
        };
      } else {
        // Herdr agents are terminal targets only when Herdr itself confirms
        // them; a down Herdr degrades honestly instead of guessing.
        const paneId = safeSessionId(agentMatch?.[1] || "");
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
        target = {
          key: `agent:${paneId}`,
          spawn: () => spawnAttachmentTerminal(herdr.attachCommand(paneId), config, spawnTerminal),
        };
      }

      const resume = parseResumeRequest(url);
      wss.handleUpgrade(request, socket, head, (websocket) => {
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

async function routeRequest(
  request: IncomingMessage,
  response: ServerResponse,
  config: HostConfig,
  tmux: SessionBackend,
  herdr?: HerdrAgentSource,
): Promise<void> {
  const url = new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);

  if (url.pathname === "/api/health" && request.method === "GET") {
    sendJson(response, 200, { ok: true, version: VERSION });
    return;
  }

  if (url.pathname.startsWith("/api/") && !isAuthorized(bearerToken(request), config.token)) {
    sendJson(response, 401, { error: "Invalid access token." });
    return;
  }

  if (url.pathname === "/api/host" && request.method === "GET") {
    const host: HostInfo = {
      name: config.machineName,
      platform: platform(),
      arch: arch(),
      version: VERSION,
      tmuxVersion: await tmux.version(),
    };
    sendJson(response, 200, host);
    return;
  }

  if (url.pathname === "/api/sessions" && request.method === "GET") {
    sendJson(response, 200, { sessions: await tmux.listSessions() });
    return;
  }

  if (url.pathname === "/api/sessions" && request.method === "POST") {
    const body = parseCreateSession(await readJsonBody(request));
    sendJson(response, 201, { session: await tmux.createSession(body) });
    return;
  }

  const sessionMatch = url.pathname.match(/^\/api\/sessions\/([^/]+)$/);
  if (sessionMatch && request.method === "DELETE") {
    const id = safeSessionId(sessionMatch[1] || "");
    if (!(await tmux.getSession(id))) {
      sendJson(response, 404, { error: "Session not found." });
      return;
    }
    await tmux.killSession(id);
    response.writeHead(204).end();
    return;
  }

  if (url.pathname === "/api/workspaces" && request.method === "GET") {
    sendJson(response, 200, { workspaces: await tmux.listWorkspaces() });
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
    sendJson(response, 200, await herdr.listAgents());
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
    // trimmed out of the ring) gets a fresh attach: tmux repaints the whole
    // screen, so the client is complete again without replay.
    attachment?.dispose();
    attachment = attachments.create(target.key, target.spawn());
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

function setCors(request: IncomingMessage, response: ServerResponse): void {
  response.setHeader("Access-Control-Allow-Origin", request.headers.origin || "*");
  response.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
  response.setHeader("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS");
  response.setHeader("Vary", "Origin");
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
