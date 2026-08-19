import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { arch, platform } from "node:os";
import * as pty from "node-pty";
import { WebSocketServer, type RawData, type WebSocket } from "ws";
import { bearerToken, isAuthorized } from "./auth.js";
import type { HostConfig } from "./config.js";
import { VERSION } from "./config.js";
import {
  MAX_TERMINAL_FRAME_BYTES,
  chunkTerminalOutput,
  parseClientTerminalMessage,
  TERMINAL_PROTOCOL,
} from "./protocol.js";
import { TmuxService } from "./tmux.js";
import type { HostInfo, ServerTerminalMessage } from "./types.js";
import { InputError, parseCreateSession, safeSessionId } from "./validation.js";

const MAX_BODY_BYTES = 64 * 1024;
const WEBSOCKET_HIGH_WATER_BYTES = 512 * 1024;
const WEBSOCKET_LOW_WATER_BYTES = 128 * 1024;
const MAX_PENDING_OUTPUT_BYTES = 1024 * 1024;
const BACKPRESSURE_POLL_MILLISECONDS = 25;

export interface MochaServerOptions {
  config: HostConfig;
  tmux: TmuxService;
  spawnTerminal?: typeof pty.spawn;
}

export async function createMochaServer(options: MochaServerOptions) {
  const { config, tmux, spawnTerminal = pty.spawn } = options;
  const wss = new WebSocketServer({
    noServer: true,
    handleProtocols(protocols) {
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
      await routeRequest(request, response, config, tmux);
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
      const match = url.pathname.match(/^\/api\/sessions\/([^/]+)\/terminal$/);
      if (!match || !isAuthorized(bearerToken(request), config.token)) {
        socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }
      if (!offersTerminalProtocol(request)) {
        socket.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }

      const id = safeSessionId(match[1] || "");
      if (!(await tmux.getSession(id))) {
        socket.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }

      wss.handleUpgrade(request, socket, head, (websocket) => {
        wss.emit("connection", websocket, request, id);
      });
    } catch {
      socket.destroy();
    }
  });

  wss.on("connection", (websocket: WebSocket, _request: IncomingMessage, id: string) => {
    try {
      bridgeTerminal(websocket, id, config, tmux, spawnTerminal);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Could not open the terminal.";
      sendTerminal(websocket, { type: "error", message });
      websocket.close(1011, "terminal unavailable");
    }
  });

  return server;
}

async function routeRequest(
  request: IncomingMessage,
  response: ServerResponse,
  config: HostConfig,
  tmux: TmuxService,
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

  if (url.pathname.startsWith("/api/")) {
    sendJson(response, 404, { error: "Not found." });
    return;
  }

  sendJson(response, 404, { error: "Not found." });
}

function bridgeTerminal(
  websocket: WebSocket,
  id: string,
  config: HostConfig,
  tmux: TmuxService,
  spawnTerminal: typeof pty.spawn,
): void {
  const env = { ...process.env };
  delete env.npm_config_prefix;
  delete env.NPM_CONFIG_PREFIX;
  const terminal = spawnTerminal(config.tmuxBin, tmux.attachArgs(id), {
    name: "xterm-256color",
    cols: 100,
    rows: 30,
    cwd: config.stateDir,
    env: {
      ...env,
      TERM: "xterm-256color",
      COLORTERM: "truecolor",
    },
    handleFlowControl: true,
  });

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
  return header?.split(",").some((protocol) => protocol.trim() === TERMINAL_PROTOCOL) ?? false;
}
