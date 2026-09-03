import { createHash, randomBytes } from "node:crypto";
import { execFile } from "node:child_process";
import {
  createServer,
  request as httpRequest,
  type IncomingHttpHeaders,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from "node:http";
import { connect } from "node:net";
import type { Duplex } from "node:stream";
import { promises as fs } from "node:fs";
import path from "node:path";
import { promisify } from "node:util";
import { isWithinRoots } from "./projects.js";

// Private dev-server preview (#58). An agent starts something on
// `localhost:<port>` on this computer; the phone shows it in a WebKit view
// without the server being started any differently and without anyone but
// the paired phone being able to open it.
//
// Shape: one *door*. Tailscale Serve publishes `https://<name>.ts.net:8443`
// once and forever → this process's loopback listener (`createPreviewDoor`).
// The door forwards nothing on its own. A request gets through only with a
// *ticket* cookie the phone obtained over the bearer-authenticated API
// (`PreviewRegistry.open`), and the ticket names the loopback port it may
// reach. So: no per-preview Tailscale state to reap, no path prefix to
// break absolute asset URLs, and a ticket that dies when the sheet closes,
// when the phone goes quiet, or when this process restarts.

export const TICKET_COOKIE = "tavi_preview";
// A preview lives while the phone keeps it alive — a heartbeat or any
// traffic through the door. This is only the net under a killed app.
export const PREVIEW_GRACE_MS = 120_000;
const SWEEP_MS = 15_000;
const PROBE_TIMEOUT_MS = 1_500;
const MAX_PREVIEWS = 32;
const LSOF_TIMEOUT_MS = 5_000;

const execFileAsync = promisify(execFile);

export type LoopbackAddress = "127.0.0.1" | "::1";

export interface Preview {
  id: string;
  deviceId: string;
  port: number;
  // Which loopback the server actually answers on; `localhost` may resolve
  // to ::1 on the machine that started it (Vite does this on macOS).
  address: LoopbackAddress;
  cwd: string;
  openedAt: number;
  lastSeenAt: number;
}

export interface OpenedPreview {
  preview: Preview;
  // Returned exactly once; the registry keeps only its hash.
  ticket: string;
}

export type OpenResult = { ok: true; opened: OpenedPreview } | { ok: false; status: 400 | 409 | 429; error: string };

export interface PreviewRegistryOptions {
  now?: () => number;
  graceMs?: number;
  probe?: (port: number) => Promise<LoopbackAddress | undefined>;
}

export class PreviewRegistry {
  private readonly byTicketHash = new Map<string, Preview>();
  private readonly now: () => number;
  private readonly graceMs: number;
  private readonly probe: (port: number) => Promise<LoopbackAddress | undefined>;
  private sweeper: NodeJS.Timeout | undefined;

  constructor(options: PreviewRegistryOptions = {}) {
    this.now = options.now ?? (() => Date.now());
    this.graceMs = options.graceMs ?? PREVIEW_GRACE_MS;
    this.probe = options.probe ?? probeLoopback;
  }

  start(): void {
    if (this.sweeper) return;
    this.sweeper = setInterval(() => this.sweep(), SWEEP_MS);
    this.sweeper.unref?.();
  }

  stop(): void {
    if (this.sweeper) clearInterval(this.sweeper);
    this.sweeper = undefined;
    this.byTicketHash.clear();
  }

  async open(input: { deviceId: string; port: unknown; cwd: string }): Promise<OpenResult> {
    const port = validPort(input.port);
    if (port === undefined) return { ok: false, status: 400, error: "port must be a number between 1 and 65535." };
    this.sweep();
    if (this.byTicketHash.size >= MAX_PREVIEWS) {
      return { ok: false, status: 429, error: "Too many previews are open on this computer. Close one first." };
    }
    const address = await this.probe(port);
    if (!address) {
      return { ok: false, status: 409, error: `Nothing is listening on localhost:${port} on this computer.` };
    }
    const ticket = randomBytes(32).toString("base64url");
    const at = this.now();
    const preview: Preview = {
      id: randomBytes(8).toString("hex"),
      deviceId: input.deviceId,
      port,
      address,
      cwd: input.cwd,
      openedAt: at,
      lastSeenAt: at,
    };
    this.byTicketHash.set(hashTicket(ticket), preview);
    return { ok: true, opened: { preview, ticket } };
  }

  // The door's lookup: a live preview for this ticket, its clock refreshed.
  admit(ticket: string | undefined): Preview | undefined {
    if (!ticket || ticket.length > 128) return undefined;
    const preview = this.byTicketHash.get(hashTicket(ticket));
    if (!preview) return undefined;
    if (this.expired(preview)) {
      this.byTicketHash.delete(hashTicket(ticket));
      return undefined;
    }
    preview.lastSeenAt = this.now();
    return preview;
  }

  // The phone's heartbeat. Only the device that opened a preview may touch it.
  touch(id: string, deviceId: string): Preview | undefined {
    const preview = this.find(id, deviceId);
    if (!preview) return undefined;
    preview.lastSeenAt = this.now();
    return preview;
  }

  close(id: string, deviceId: string): boolean {
    for (const [hash, preview] of this.byTicketHash) {
      if (preview.id === id && preview.deviceId === deviceId) {
        this.byTicketHash.delete(hash);
        return true;
      }
    }
    return false;
  }

  list(deviceId: string): Preview[] {
    this.sweep();
    return [...this.byTicketHash.values()].filter((preview) => preview.deviceId === deviceId);
  }

  // Is the server behind a preview still there? (The phone's heartbeat asks.)
  async listening(preview: Preview): Promise<boolean> {
    return (await this.probe(preview.port)) !== undefined;
  }

  get size(): number {
    return this.byTicketHash.size;
  }

  private find(id: string, deviceId: string): Preview | undefined {
    this.sweep();
    for (const preview of this.byTicketHash.values()) {
      if (preview.id === id && preview.deviceId === deviceId) return preview;
    }
    return undefined;
  }

  private expired(preview: Preview): boolean {
    return this.now() - preview.lastSeenAt > this.graceMs;
  }

  private sweep(): void {
    for (const [hash, preview] of this.byTicketHash) {
      if (this.expired(preview)) this.byTicketHash.delete(hash);
    }
  }
}

function hashTicket(ticket: string): string {
  return createHash("sha256").update(ticket).digest("hex");
}

export function validPort(value: unknown): number | undefined {
  const port = typeof value === "string" ? Number.parseInt(value, 10) : value;
  return typeof port === "number" && Number.isInteger(port) && port >= 1 && port <= 65_535 ? port : undefined;
}

// Is anything accepting connections on this port, on which loopback?
export async function probeLoopback(port: number): Promise<LoopbackAddress | undefined> {
  for (const address of ["127.0.0.1", "::1"] as const) {
    if (await accepts(address, port)) return address;
  }
  return undefined;
}

function accepts(address: LoopbackAddress, port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = connect({ host: address, port });
    const done = (ok: boolean) => {
      socket.destroy();
      resolve(ok);
    };
    socket.setTimeout(PROBE_TIMEOUT_MS, () => done(false));
    socket.once("connect", () => done(true));
    socket.once("error", () => done(false));
  });
}

// ---------------------------------------------------------------------------
// The door: the loopback HTTP server Tailscale Serve fronts.

export interface PreviewDoorOptions {
  registry: PreviewRegistry;
  // Test seam; production forwards to the preview's loopback address.
  target?: (preview: Preview) => { host: string; port: number };
}

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
        const headers = answerHeaders(answer.rawHeaders, preview.port);
        response.writeHead(answer.statusCode ?? 502, answer.statusMessage, headers);
        answer.pipe(response);
        answer.on("error", () => response.destroy());
      },
    );
    proxied.on("error", () => {
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
    proxied.on("upgrade", (answer, upstreamSocket, upstreamHead) => {
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
export function answerHeaders(rawHeaders: string[], port: number): string[] {
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

// ---------------------------------------------------------------------------
// Discovery: which dev servers belong to this project.

export interface ListeningServer {
  port: number;
  pid: number;
  command: string;
  cwd: string;
}

export type CandidatesResult = { available: true; servers: ListeningServer[] } | { available: false; reason: string };

export interface DiscoveryDeps {
  // Never offered: this host process and its own ports (the host runs from
  // a checkout inside the roots on the owner's Mac and would list itself).
  exclude?: { pids?: number[]; ports?: number[] };
  // `lsof -nP -iTCP -sTCP:LISTEN -F pcn`
  listListeners: () => Promise<string>;
  // `lsof -a -p <pids> -d cwd -Fn`
  listCwds: (pids: number[]) => Promise<string>;
  realpath: (target: string) => Promise<string>;
}

export function defaultDiscoveryDeps(): DiscoveryDeps {
  const lsof = async (args: string[]): Promise<string> => {
    try {
      const { stdout } = await execFileAsync("lsof", args, { timeout: LSOF_TIMEOUT_MS, maxBuffer: 8 * 1024 * 1024 });
      return stdout;
    } catch (error) {
      // lsof exits 1 when *some* pid had nothing to report; its stdout is
      // still the answer for the others.
      const failed = error as { stdout?: string; code?: string };
      if (typeof failed.stdout === "string" && failed.code !== "ENOENT") return failed.stdout;
      throw error;
    }
  };
  return {
    listListeners: () => lsof(["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]),
    listCwds: (pids) => lsof(["-a", "-p", pids.join(","), "-d", "cwd", "-Fn"]),
    realpath: (target) => fs.realpath(target),
  };
}

// Dev servers this project is running: processes listening on a loopback or
// wildcard TCP port whose working directory is this project (or a parent of
// it — a monorepo's root dev server counts for the app inside it), and
// inside the configured roots either way.
export async function listProjectServers(
  cwd: string,
  roots: readonly string[],
  deps: DiscoveryDeps = defaultDiscoveryDeps(),
): Promise<CandidatesResult> {
  let listeners: string;
  try {
    listeners = await deps.listListeners();
  } catch (error) {
    const code = (error as { code?: string }).code;
    return {
      available: false,
      reason:
        code === "ENOENT"
          ? "lsof is not installed on this computer, so Tavi cannot find dev servers by itself. Type the port instead."
          : "Tavi could not list this computer's open ports. Type the port instead.",
    };
  }
  const candidates = parseListeners(listeners);
  if (candidates.length === 0) return { available: true, servers: [] };
  const pids = [...new Set(candidates.map((candidate) => candidate.pid))];
  const cwds = parseCwds(await deps.listCwds(pids).catch(() => ""));
  const projectReal = await deps.realpath(cwd).catch(() => undefined);
  if (!projectReal) return { available: true, servers: [] };
  // Roots as they really are, so `/var` vs `/private/var` never decides anything.
  const realRoots = (await Promise.all(roots.map((root) => deps.realpath(root).catch(() => root)))).concat(roots);
  const servers: ListeningServer[] = [];
  const seen = new Set<number>();
  const excludedPids = new Set([process.pid, ...(deps.exclude?.pids ?? [])]);
  const excludedPorts = new Set(deps.exclude?.ports ?? []);
  for (const candidate of candidates) {
    if (seen.has(candidate.port) || excludedPids.has(candidate.pid) || excludedPorts.has(candidate.port)) continue;
    const processCwd = cwds.get(candidate.pid);
    if (!processCwd) continue;
    const processReal = await deps.realpath(processCwd).catch(() => undefined);
    if (!processReal) continue;
    const related = isInside(processReal, projectReal) || isInside(projectReal, processReal);
    if (!related || !isWithinRoots(processReal, realRoots)) continue;
    seen.add(candidate.port);
    servers.push({ port: candidate.port, pid: candidate.pid, command: candidate.command, cwd: processReal });
  }
  servers.sort((a, b) => a.port - b.port);
  return { available: true, servers };
}

function isInside(candidate: string, parent: string): boolean {
  const relative = path.relative(parent, candidate);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

interface Listener {
  pid: number;
  command: string;
  port: number;
}

// lsof -F pcn: `p<pid>`, `c<command>`, then `n<addr>:<port>` per socket.
export function parseListeners(output: string): Listener[] {
  const listeners: Listener[] = [];
  let pid = 0;
  let command = "";
  for (const line of output.split("\n")) {
    const tag = line[0];
    const value = line.slice(1);
    if (tag === "p") {
      pid = Number.parseInt(value, 10);
      command = "";
    } else if (tag === "c") {
      command = value;
    } else if (tag === "n" && pid > 0) {
      const port = loopbackPort(value);
      if (port !== undefined) listeners.push({ pid, command, port });
    }
  }
  return listeners;
}

// `127.0.0.1:5173`, `[::1]:5173`, `*:5173`, `localhost:5173` are reachable
// from this machine's loopback; a bind to one LAN address only is not.
export function loopbackPort(name: string): number | undefined {
  const match = /^(\*|localhost|127\.0\.0\.1|\[::1\]|\[::\]|0\.0\.0\.0):(\d+)$/.exec(name.trim());
  if (!match) return undefined;
  return validPort(match[2]);
}

// lsof -a -p … -d cwd -Fn: `p<pid>` then `fcwd` then `n<path>`.
export function parseCwds(output: string): Map<number, string> {
  const cwds = new Map<number, string>();
  let pid = 0;
  for (const line of output.split("\n")) {
    if (line.startsWith("p")) pid = Number.parseInt(line.slice(1), 10);
    else if (line.startsWith("n") && pid > 0 && !cwds.has(pid)) cwds.set(pid, line.slice(1));
  }
  return cwds;
}

// "Stop server" from the phone: the process that owns this project's port,
// asked politely. Re-discovered at the moment of the tap so a pid is never
// trusted from an earlier list.
export async function stopProjectServer(
  cwd: string,
  port: number,
  roots: readonly string[],
  deps: DiscoveryDeps & { kill?: (pid: number) => void } = defaultDiscoveryDeps(),
): Promise<{ ok: true; pid: number; command: string } | { ok: false; status: 404 | 503; error: string }> {
  const found = await listProjectServers(cwd, roots, deps);
  if (!found.available) return { ok: false, status: 503, error: found.reason };
  const server = found.servers.find((candidate) => candidate.port === port);
  if (!server) return { ok: false, status: 404, error: `No server of this project is listening on localhost:${port}.` };
  if (server.pid <= 1 || server.pid === process.pid)
    return { ok: false, status: 404, error: "That process is not one Tavi will stop." };
  (deps.kill ?? ((pid: number) => process.kill(pid, "SIGTERM")))(server.pid);
  return { ok: true, pid: server.pid, command: server.command };
}
