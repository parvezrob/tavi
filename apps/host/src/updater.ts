import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { promisify } from "node:util";
import {
  clearPending,
  currentVersion,
  packageRootFor,
  pruneVersions,
  readPending,
  type RuntimeLayout,
  switchCurrent,
  versionPrefix,
  writePending,
} from "./runtime.js";

// Keeps a managed host current without anyone running a command: once a
// day (and shortly after start) ask npm for the latest tavi-host, install it
// beside the running version, point `current` at it, and restart. Same
// major version only; the previous copy stays for the launcher's rollback.
const execFileAsync = promisify(execFile);
const REGISTRY = process.env.TAVI_UPDATE_REGISTRY || "https://registry.npmjs.org";
const PACKAGE_NAME = "tavi-host";

export type UpdateOutcome =
  | { status: "current"; version: string }
  | { status: "updated"; from: string; to: string }
  | { status: "skipped"; reason: string }
  | { status: "failed"; reason: string };

export interface UpdaterDeps {
  currentVersion: string;
  layout: RuntimeLayout;
  fetchLatest: () => Promise<string | undefined>;
  install: (version: string, prefix: string) => Promise<void>;
  /** Runs the installed copy's `--version` and returns what it prints. */
  verify: (packageRoot: string) => Promise<string>;
  restart: () => void;
  log: (message: string) => void;
}

export function defaultUpdaterDeps(input: {
  currentVersion: string;
  layout: RuntimeLayout;
  restart: () => void;
  log?: (message: string) => void;
}): UpdaterDeps {
  return {
    currentVersion: input.currentVersion,
    layout: input.layout,
    log: input.log ?? ((message) => console.log(message)),
    restart: input.restart,
    fetchLatest: async () => {
      const response = await fetch(`${REGISTRY}/${PACKAGE_NAME}/latest`, { signal: AbortSignal.timeout(10_000) }).catch(
        () => undefined,
      );
      if (!response?.ok) return undefined;
      const body = (await response.json().catch(() => ({}))) as { version?: unknown };
      return typeof body.version === "string" ? body.version : undefined;
    },
    install: async (version, prefix) => {
      await execFileAsync(
        npmPath(),
        ["install", "--prefix", prefix, "--no-audit", "--no-fund", "--loglevel=error", `${PACKAGE_NAME}@${version}`],
        {
          timeout: 300_000,
          env: { ...process.env, PATH: process.env.PATH || "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" },
        },
      );
    },
    verify: async (packageRoot) => {
      const { stdout } = await execFileAsync(
        process.execPath,
        [path.join(packageRoot, "dist", "index.js"), "--version"],
        { timeout: 20_000 },
      );
      return stdout.trim();
    },
  };
}

/** Newer, same major, no prerelease tag. */
export function newerCompatible(current: string, latest: string): boolean {
  const a = parse(current);
  const b = parse(latest);
  if (!a || !b) return false;
  if (a.major !== b.major) return false;
  return b.minor > a.minor || (b.minor === a.minor && b.patch > a.patch);
}

export async function checkAndApply(deps: UpdaterDeps): Promise<UpdateOutcome> {
  const latest = await deps.fetchLatest();
  if (!latest) return { status: "failed", reason: "could not reach npm to check for updates" };
  if (!newerCompatible(deps.currentVersion, latest)) return { status: "current", version: deps.currentVersion };

  const packageRoot = packageRootFor(deps.layout, latest);
  try {
    if (!existsSync(path.join(packageRoot, "dist", "index.js"))) {
      deps.log(`Updating Tavi ${deps.currentVersion} → ${latest}…`);
      await deps.install(latest, versionPrefix(deps.layout, latest));
    }
    const reported = await deps.verify(packageRoot);
    if (reported !== latest) {
      return {
        status: "failed",
        reason: `the downloaded copy reports version ${reported || "(nothing)"}, expected ${latest}`,
      };
    }
  } catch (error) {
    return { status: "failed", reason: describe(error) };
  }

  const previous = currentVersion(deps.layout);
  writePending(deps.layout, {
    version: latest,
    attempts: 0,
    startedAt: new Date().toISOString(),
    ...(previous ? { previous } : {}),
  });
  switchCurrent(deps.layout, latest);
  pruneVersions(deps.layout, [latest, ...(previous ? [previous] : [])]);
  deps.log(`Tavi ${latest} installed; restarting.`);
  deps.restart();
  return { status: "updated", from: deps.currentVersion, to: latest };
}

/** Called once the host is listening: the update that started us is a success. */
export function markStarted(layout: RuntimeLayout, version: string): boolean {
  const pending = readPending(layout);
  if (!pending || pending.version !== version) return false;
  clearPending(layout);
  return true;
}

export interface UpdaterSchedule {
  initialDelayMs?: number;
  intervalMs?: number;
  /** After a failed check (npm unreachable, tarball not propagated yet) — sooner than the daily interval. */
  retryMs?: number;
  setTimer?: (fn: () => void, ms: number) => { unref?: () => void };
}

export function startUpdater(
  deps: UpdaterDeps,
  schedule: UpdaterSchedule = {},
): { checkNow: () => Promise<UpdateOutcome>; stop: () => void } {
  const initial = schedule.initialDelayMs ?? 2 * 60_000;
  const interval = schedule.intervalMs ?? 24 * 60 * 60_000;
  const retry = schedule.retryMs ?? 60 * 60_000;
  const setTimer = schedule.setTimer ?? ((fn, ms) => setTimeout(fn, ms));
  let inFlight: Promise<UpdateOutcome> | undefined;
  let stopped = false;

  const checkNow = (): Promise<UpdateOutcome> => {
    if (!inFlight) {
      inFlight = checkAndApply(deps).finally(() => {
        inFlight = undefined;
      });
    }
    return inFlight;
  };
  const tick = (): void => {
    if (stopped) return;
    void checkNow().then((outcome) => {
      if (stopped) return;
      const failed = outcome.status === "failed";
      if (failed) deps.log(`Update check: ${outcome.reason}; trying again in about an hour.`);
      setTimer(tick, jitter(failed ? retry : interval)).unref?.();
    });
  };
  setTimer(tick, initial).unref?.();
  return {
    checkNow,
    stop: () => {
      stopped = true;
    },
  };
}

function jitter(ms: number): number {
  return Math.round(ms * (0.9 + Math.random() * 0.2));
}

function parse(version: string): { major: number; minor: number; patch: number } | undefined {
  const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(version.trim());
  if (!match) return undefined;
  return { major: Number(match[1]), minor: Number(match[2]), patch: Number(match[3]) };
}

function npmPath(): string {
  const beside = path.join(path.dirname(process.execPath), "npm");
  return existsSync(beside) ? beside : "npm";
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
