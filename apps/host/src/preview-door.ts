import {
  createServer,
  request as httpRequest,
  type IncomingHttpHeaders,
  type Server,
  type ServerResponse,
} from "node:http";
import type { Duplex } from "node:stream";
import { PROBE_TIMEOUT_MS, type Preview, type PreviewRegistry, TICKET_COOKIE } from "./preview.js";

// The door: the loopback HTTP server Tailscale Serve fronts (#58). Split
// out of preview.ts in #98 — the registry decides who may reach which
// loopback port; this moves the bytes.

export interface PreviewDoorOptions {
  registry: PreviewRegistry;
  // Test seam; production forwards to the preview's loopback address.
  target?: (preview: Preview) => { host: string; port: number };
  // Test seam; production waits UPSTREAM_ANSWER_TIMEOUT_MS for a first byte.
  answerTimeoutMs?: number;
}

// How long an upstream gets to start answering before the door answers for
// it (#98). Thirty times the 1.5 s the registry gives a dev server to accept
// a connection at all: a Next.js route compiling cold on first request can
// take well past 15 s, and cutting that off would be the bug, not the fix —
// while a hung server must not hold the phone's tab spinning forever with no
// message. Cleared the moment the answer starts, so a long response body, an
// SSE stream, or an idle HMR socket is never cut off.
const UPSTREAM_ANSWER_TIMEOUT_MS = PROBE_TIMEOUT_MS * 30;

const HOP_BY_HOP = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
  "proxy-connection",
]);

export function createPreviewDoor(options: PreviewDoorOptions): Server {
  const { registry } = options;
  const target = options.target ?? ((preview: Preview) => ({ host: preview.address, port: preview.port }));
  const answerTimeoutMs = options.answerTimeoutMs ?? UPSTREAM_ANSWER_TIMEOUT_MS;

  const server = createServer((request, response) => {
    const preview = registry.admit(ticketFrom(request.headers.cookie));
    if (!preview) {
      refuse(
        response,
        401,
        "Open this from Tavi",
        "This page is a private preview. Open it from the Tavi app on your phone, where the agent's terminal is.",
      );
      return;
    }
    const upstream = target(preview);
    const proxied = httpRequest(
      {
        host: upstream.host,
        port: upstream.port,
        method: request.method,
        path: request.url,
        headers: forwardHeaders(request.headers, preview.port, false),
        setHost: false,
      },
      (answer) => {
        proxied.setTimeout(0);
        const headers = answerHeaders(answer.rawHeaders, preview.port);
        response.writeHead(answer.statusCode ?? 502, answer.statusMessage, headers);
        answer.pipe(response);
        answer.on("error", () => response.destroy());
      },
    );
    proxied.setTimeout(answerTimeoutMs, () => {
      if (!response.headersSent) {
        refuse(
          response,
          504,
          `localhost:${preview.port} is not answering`,
          "The dev server accepted the connection but sent nothing back in time. Check it in the agent's terminal, then reload.",
        );
      }
      proxied.destroy();
    });
    proxied.on("error", () => {
      // The timeout above already answered and ended the response; the error
      // this destroy raises must not write a second body onto it.
      if (response.writableEnded) return;
      if (response.headersSent) {
        response.destroy();
        return;
      }
      refuse(
        response,
        502,
        `Nothing is answering on localhost:${preview.port}`,
        "The dev server this preview was showing has stopped or is not accepting connections. Start it again in the agent's terminal, then reopen the preview.",
      );
    });
    request.pipe(proxied);
    request.on("aborted", () => proxied.destroy());
  });

  // HMR is a WebSocket; a preview that never hot-reloads reads as broken.
  server.on("upgrade", (request, socket, head) => {
    const preview = registry.admit(ticketFrom(request.headers.cookie));
    if (!preview) {
      socket.end("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
      return;
    }
    const upstream = target(preview);
    const proxied = httpRequest({
      host: upstream.host,
      port: upstream.port,
      method: request.method,
      path: request.url,
      headers: forwardHeaders(request.headers, preview.port, true),
      setHost: false,
    });
    // The handshake is bounded; the socket it becomes is not — an HMR
    // connection is idle most of its life.
    proxied.setTimeout(answerTimeoutMs, () => {
      socket.destroy();
      proxied.destroy();
    });
    proxied.on("upgrade", (answer, upstreamSocket, upstreamHead) => {
      proxied.setTimeout(0);
      const lines = [`HTTP/1.1 ${answer.statusCode ?? 101} ${answer.statusMessage ?? "Switching Protocols"}`];
      for (let index = 0; index + 1 < answer.rawHeaders.length; index += 2) {
        lines.push(`${answer.rawHeaders[index]}: ${answer.rawHeaders[index + 1]}`);
      }
      socket.write(`${lines.join("\r\n")}\r\n\r\n`);
      if (upstreamHead.length > 0) socket.write(upstreamHead);
      pipeBoth(socket, upstreamSocket);
    });
    // The dev server declined to upgrade: relay its answer and close.
    proxied.on("response", (answer) => {
      proxied.setTimeout(0);
      const lines = [`HTTP/1.1 ${answer.statusCode ?? 502} ${answer.statusMessage ?? ""}`, "Connection: close"];
      for (let index = 0; index + 1 < answer.rawHeaders.length; index += 2) {
        if (answer.rawHeaders[index]?.toLowerCase() === "connection") continue;
        lines.push(`${answer.rawHeaders[index]}: ${answer.rawHeaders[index + 1]}`);
      }
      socket.write(`${lines.join("\r\n")}\r\n\r\n`);
      answer.pipe(socket);
    });
    proxied.on("error", () => socket.destroy());
    socket.on("error", () => proxied.destroy());
    proxied.end(head);
  });

  return server;
}

function pipeBoth(a: Duplex, b: Duplex): void {
  a.pipe(b);
  b.pipe(a);
  const drop = () => {
    a.destroy();
    b.destroy();
  };
  a.on("error", drop);
  b.on("error", drop);
  a.on("close", drop);
  b.on("close", drop);
}

export function ticketFrom(cookieHeader: string | undefined): string | undefined {
  if (!cookieHeader) return undefined;
  for (const part of cookieHeader.split(";")) {
    const [name, ...rest] = part.trim().split("=");
    if (name === TICKET_COOKIE) return rest.join("=");
  }
  return undefined;
}

// What the dev server sees. It believes it is talking to a browser on this
// very machine: Host and Origin say `localhost:<port>` (Vite's and Next's
// allowed-host checks refuse anything else), our ticket cookie is gone
// (the dev app never learns it), the rest passes as-is.
export function forwardHeaders(
  incoming: IncomingHttpHeaders,
  port: number,
  upgrade: boolean,
): Record<string, string | string[]> {
  const headers: Record<string, string | string[]> = {};
  for (const [name, value] of Object.entries(incoming)) {
    if (value === undefined) continue;
    if (HOP_BY_HOP.has(name) && !(upgrade && (name === "connection" || name === "upgrade"))) continue;
    headers[name] = value;
  }
  const originalHost = typeof incoming.host === "string" ? incoming.host : "";
  headers.host = `localhost:${port}`;
  if (typeof incoming.origin === "string") headers.origin = `http://localhost:${port}`;
  if (typeof incoming.referer === "string") {
    try {
      const referer = new URL(incoming.referer);
      headers.referer = `http://localhost:${port}${referer.pathname}${referer.search}`;
    } catch {
      // A Referer the dev server sent that will not parse cannot be
      // rewritten to localhost, and forwarding it as-is would leak the
      // tailnet host name into the page's own requests.
      delete headers.referer;
    }
  }
  const remaining = stripTicketCookie(typeof incoming.cookie === "string" ? incoming.cookie : undefined);
  if (remaining) headers.cookie = remaining;
  else delete headers.cookie;
  if (originalHost) headers["x-forwarded-host"] = originalHost;
  headers["x-forwarded-proto"] = "https";
  return headers;
}

export function stripTicketCookie(cookieHeader: string | undefined): string | undefined {
  if (!cookieHeader) return undefined;
  const kept = cookieHeader
    .split(";")
    .map((part) => part.trim())
    .filter((part) => part.length > 0 && !part.startsWith(`${TICKET_COOKIE}=`));
  return kept.length > 0 ? kept.join("; ") : undefined;
}

// The dev server's answer, with one fix: a redirect to its own
// `http://localhost:<port>/x` becomes `/x`, which the phone follows through
// the door instead of into a localhost it does not have.
function answerHeaders(rawHeaders: string[], port: number): string[] {
  const out: string[] = [];
  for (let index = 0; index + 1 < rawHeaders.length; index += 2) {
    const name = rawHeaders[index] ?? "";
    let value = rawHeaders[index + 1] ?? "";
    const lower = name.toLowerCase();
    if (HOP_BY_HOP.has(lower)) continue;
    if (lower === "location") value = relativizeLocalhost(value, port);
    out.push(name, value);
  }
  return out;
}

export function relativizeLocalhost(location: string, port: number): string {
  const match = /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(?::(\d+))?(\/.*)?$/i.exec(location.trim());
  if (!match) return location;
  const locationPort = match[2] ? Number.parseInt(match[2], 10) : 80;
  if (locationPort !== port) return location;
  return match[3] ?? "/";
}

function refuse(response: ServerResponse, status: number, title: string, body: string): void {
  const html = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(title)}</title><style>body{font:17px/1.45 -apple-system,system-ui,sans-serif;color:#2a2a2a;background:#f5f4f2;margin:0;padding:15vh 24px}h1{font-size:22px;margin:0 0 12px}p{max-width:34em;margin:0;color:#5a5a5a}</style><h1>${escapeHtml(title)}</h1><p>${escapeHtml(body)}</p>`;
  response.writeHead(status, {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Content-Length": String(Buffer.byteLength(html)),
  });
  response.end(html);
}

function escapeHtml(text: string): string {
  return text.replace(
    /[&<>"']/g,
    (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char] ?? char,
  );
}
