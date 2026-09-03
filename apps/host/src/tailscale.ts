import { execFile } from "node:child_process";
import { access } from "node:fs/promises";
import type { IncomingMessage } from "node:http";
import { promisify } from "node:util";
import { resolveOnLoginPath } from "./login-shell.js";

// The caller's path to this computer, from the computer's own Tailscale
// (#86 / #84, PRD §7.13): "direct" when the phone reaches us peer to peer,
// "relay" when its packets come through a DERP server, "unknown" when
// Tailscale cannot be asked (not installed, not running, the caller is not
// a tailnet peer). The phone says this in words — "Live · 40 ms · relay" —
// instead of blaming the computer for a slow link. Nothing here is a
// guardrail: a wrong answer costs a word on a screen, never access.

const execFileAsync = promisify(execFile);

export type TailscaleRunner = (args: string[]) => Promise<{ stdout: string }>;

export interface ConnectionPath {
  path: "direct" | "relay" | "unknown";
  relay?: string;
}

const STATUS_CACHE_MS = 5_000;
const STATUS_TIMEOUT_MS = 3_000;
const RESOLVE_RETRY_MS = 30_000;
// Where the binary lives when it is not on the login-shell PATH: the Mac
// App Store / standalone app, Homebrew, Linux packages.
const BINARY_CANDIDATES = [
  "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
  "/opt/homebrew/bin/tailscale",
  "/usr/local/bin/tailscale",
  "/usr/bin/tailscale",
];

let shell = process.env.SHELL || "/bin/sh";
let resolved: Promise<string | null> | null = null;
let resolvedAt = 0;

export function configureTailscale(loginShell: string): void {
  shell = loginShell;
  resolved = null;
  statusCache = null;
}

export function tailscaleBinary(): Promise<string | null> {
  const now = Date.now();
  if (resolved && (now - resolvedAt < RESOLVE_RETRY_MS || resolvedAt === -1)) return resolved;
  resolvedAt = now;
  resolved = (async () => {
    const onPath = await resolveOnLoginPath(shell, "tailscale");
    if (onPath) {
      resolvedAt = -1;
      return onPath;
    }
    for (const candidate of BINARY_CANDIDATES) {
      try {
        await access(candidate);
        resolvedAt = -1;
        return candidate;
      } catch {
        // next
      }
    }
    return null;
  })();
  return resolved;
}

const defaultRunner: TailscaleRunner = async (args) => {
  const binary = await tailscaleBinary();
  if (!binary) throw new Error("tailscale is not installed");
  const { stdout } = await execFileAsync(binary, args, {
    timeout: STATUS_TIMEOUT_MS,
    encoding: "utf8",
    maxBuffer: 4 * 1024 * 1024,
  });
  return { stdout };
};

// The tailnet address the request came from. Behind Tailscale Serve the
// socket peer is 127.0.0.1 and the caller is the first X-Forwarded-For
// hop; a direct localhost call (the host's own tests, curl on the Mac)
// has no such header. Only a tailnet address is worth asking about.
export function callerAddress(request: Pick<IncomingMessage, "headers" | "socket">): string | null {
  const forwarded = request.headers["x-forwarded-for"];
  const first = (Array.isArray(forwarded) ? forwarded[0] : forwarded)?.split(",")[0]?.trim();
  const candidate = first || request.socket?.remoteAddress || null;
  if (!candidate) return null;
  const bare = candidate.startsWith("::ffff:") ? candidate.slice("::ffff:".length) : candidate;
  return isTailnetAddress(bare) ? bare : null;
}

// 100.64.0.0/10 (CGNAT, Tailscale's IPv4 range) or fd7a:115c:a1e0::/48.
export function isTailnetAddress(address: string): boolean {
  const v4 = /^100\.(\d{1,3})\.\d{1,3}\.\d{1,3}$/.exec(address);
  if (v4) {
    const second = Number(v4[1]);
    return second >= 64 && second <= 127;
  }
  return address.toLowerCase().startsWith("fd7a:115c:a1e0:");
}

// Pure: `tailscale status --json` → the path for one peer address.
export function describePeerPath(status: unknown, address: string): ConnectionPath {
  if (!status || typeof status !== "object") return { path: "unknown" };
  const record = status as { Self?: unknown; Peer?: Record<string, unknown> };
  if (hasAddress(record.Self, address)) return { path: "direct" };
  const peers = record.Peer && typeof record.Peer === "object" ? Object.values(record.Peer) : [];
  const peer = peers.find((entry) => hasAddress(entry, address)) as { CurAddr?: unknown; Relay?: unknown } | undefined;
  if (!peer) return { path: "unknown" };
  if (typeof peer.CurAddr === "string" && peer.CurAddr.length > 0) return { path: "direct" };
  if (typeof peer.Relay === "string" && peer.Relay.length > 0) return { path: "relay", relay: peer.Relay };
  return { path: "unknown" };
}

function hasAddress(node: unknown, address: string): boolean {
  if (!node || typeof node !== "object") return false;
  const ips = (node as { TailscaleIPs?: unknown }).TailscaleIPs;
  return Array.isArray(ips) && ips.some((ip) => typeof ip === "string" && ip === address);
}

let statusCache: { at: number; value: unknown; refreshing: Promise<unknown> | null } | null = null;

// The status is refreshed in the background at most every 5 s and never
// waited for: the phone's latency probe is this very route, and a spawn
// per probe put 60 ms on every number the header showed (owner, 2026-09-03
// 01:00). The first answer after a start is "unknown"; the next is right.
function status(runner: TailscaleRunner, wait: boolean): Promise<unknown> {
  const now = Date.now();
  // biome-ignore lint/suspicious/noAssignInExpressions: one lazy init — the local and the module cache must be the same object.
  const cache = statusCache ?? (statusCache = { at: 0, value: null, refreshing: null });
  if (now - cache.at >= STATUS_CACHE_MS && !cache.refreshing) {
    cache.refreshing = runner(["status", "--json"])
      .then(({ stdout }) => JSON.parse(stdout) as unknown)
      .catch(() => null)
      .then((value) => {
        cache.value = value;
        cache.at = Date.now();
        cache.refreshing = null;
        return value;
      });
  }
  if (wait && cache.refreshing) return cache.refreshing;
  return Promise.resolve(cache.value);
}

export async function connectionPath(
  request: Pick<IncomingMessage, "headers" | "socket">,
  runner: TailscaleRunner = defaultRunner,
  // Tests wait for the answer; the route never does.
  wait = false,
): Promise<ConnectionPath> {
  const address = callerAddress(request);
  if (!address) return { path: "unknown" };
  try {
    return describePeerPath(await status(runner, wait), address);
  } catch {
    // `/api/host` says how the phone reached this computer; "unknown" is an
    // honest answer, and no route depends on it.
    return { path: "unknown" };
  }
}
