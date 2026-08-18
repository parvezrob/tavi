import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { arch, platform } from "node:os";
import * as pty from "node-pty";
import { WebSocketServer, type RawData, type WebSocket } from "ws";
import { bearerToken, isAuthorized, websocketToken } from "./auth.js";
import type { HostConfig } from "./config.js";
import { VERSION } from "./config.js";
import { TmuxService } from "./tmux.js";
import type { ClientTerminalMessage, HostInfo, ServerTerminalMessage } from "./types.js";
import { InputError, parseCreateSession, safeSessionId } from "./validation.js";

const MAX_BODY_BYTES = 64 * 1024;

interface DeckServerOptions {
  config: HostConfig;
  tmux: TmuxService;
}

export async function createDeckServer(options: DeckServerOptions) {
  const { config, tmux } = options;
  const wss = new WebSocketServer({
    noServer: true,
    handleProtocols(protocols) {
      return protocols.has("deck.v1") ? "deck.v1" : false;
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
      if (!match || !isAuthorized(websocketToken(request), config.token)) {
        socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
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
      bridgeTerminal(websocket, id, config, tmux);
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

function bridgeTerminal(websocket: WebSocket, id: string, config: HostConfig, tmux: TmuxService): void {
  const env = { ...process.env };
  delete env.npm_config_prefix;
  delete env.NPM_CONFIG_PREFIX;
  const terminal = pty.spawn(config.tmuxBin, tmux.attachArgs(id), {
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

  sendTerminal(websocket, { type: "ready" });
  terminal.onData((data) => sendTerminal(websocket, { type: "output", data }));
  terminal.onExit(({ exitCode, signal }) => {
    sendTerminal(websocket, {
      type: "exit",
      code: exitCode,
      ...(typeof signal === "number" ? { signal } : {}),
    });
    websocket.close(1000, "terminal exited");
  });

  websocket.on("message", (raw: RawData) => {
    if (Buffer.byteLength(raw.toString()) > MAX_BODY_BYTES) return;
    try {
      const message = JSON.parse(raw.toString()) as ClientTerminalMessage;
      if (message.type === "input" && typeof message.data === "string") {
        terminal.write(message.data.slice(0, MAX_BODY_BYTES));
      } else if (
        message.type === "resize" &&
        Number.isInteger(message.cols) &&
        Number.isInteger(message.rows)
      ) {
        terminal.resize(clamp(message.cols, 20, 400), clamp(message.rows, 5, 200));
      }
    } catch {
      sendTerminal(websocket, { type: "error", message: "Invalid terminal message." });
    }
  });

  websocket.once("close", () => terminal.kill());
  websocket.once("error", () => terminal.kill());
}

function sendTerminal(websocket: WebSocket, message: ServerTerminalMessage): void {
  if (websocket.readyState === websocket.OPEN) websocket.send(JSON.stringify(message));
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
