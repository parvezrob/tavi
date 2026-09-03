import { execFile } from "node:child_process";
import { promises as fs } from "node:fs";
import path from "node:path";
import { promisify } from "node:util";
import { validPort } from "./preview.js";
import { isWithinRoots } from "./projects.js";

const execFileAsync = promisify(execFile);
const LSOF_TIMEOUT_MS = 5_000;

// Discovery: which dev servers belong to this project (#58). Split out of
// preview.ts in #98 — asking `lsof` what is listening is its own subject.

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
