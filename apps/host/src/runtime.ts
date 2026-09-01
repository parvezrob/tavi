import { existsSync, mkdirSync, readdirSync, readFileSync, readlinkSync, renameSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import path from "node:path";

// The managed runtime: where a host installed by `npx tavi-host pair` lives
// and how it updates itself without anyone re-running a command.
//
//   ~/.tavi/runtime/
//     launcher.mjs            stable entry the service runs; never updated by the updater
//     current -> versions/0.1.6
//     versions/0.1.6/node_modules/tavi-host/   one npm --prefix install per version
//     versions/0.1.5/…                         the previous one, kept for rollback
//     pending-update.json     present from "switched" until the new version starts cleanly
//
// The launcher counts start attempts while pending-update.json exists; after
// three failures it points `current` back at the previous version and the
// supervisor (launchd / systemd) brings the old copy up. The host clears the
// pending file once it is listening.
export interface RuntimeLayout {
  root: string;
  versionsDir: string;
  currentLink: string;
  launcher: string;
  pendingFile: string;
}

export interface PendingUpdate {
  version: string;
  previous?: string;
  attempts: number;
  startedAt: string;
}

export const MAX_START_ATTEMPTS = 3;

export function runtimeLayout(stateDir: string): RuntimeLayout {
  const root = path.join(stateDir, "runtime");
  return {
    root,
    versionsDir: path.join(root, "versions"),
    currentLink: path.join(root, "current"),
    launcher: path.join(root, "launcher.mjs"),
    pendingFile: path.join(root, "pending-update.json"),
  };
}

/** The npm --prefix directory for one version. */
export function versionPrefix(layout: RuntimeLayout, version: string): string {
  return path.join(layout.versionsDir, version);
}

/** Where the package itself lands inside that prefix. */
export function packageRootFor(layout: RuntimeLayout, version: string): string {
  return path.join(versionPrefix(layout, version), "node_modules", "tavi-host");
}

/** True when this code runs from the managed runtime (so it may update itself). */
export function isManagedRuntime(packageRoot: string, stateDir: string): boolean {
  const layout = runtimeLayout(stateDir);
  const resolved = path.resolve(packageRoot);
  return [layout.versionsDir, layout.currentLink].some((prefix) => resolved.startsWith(path.resolve(prefix) + path.sep));
}

export function currentVersion(layout: RuntimeLayout): string | undefined {
  try {
    return path.basename(readlinkSync(layout.currentLink));
  } catch {
    return undefined;
  }
}

/** Atomically repoints `current` at a version (symlink written beside, then renamed over). */
export function switchCurrent(layout: RuntimeLayout, version: string): void {
  mkdirSync(layout.root, { recursive: true });
  const temporary = `${layout.currentLink}.${process.pid}.tmp`;
  try {
    unlinkSync(temporary);
  } catch {
    // Nothing stale to remove.
  }
  symlinkSync(path.join("versions", version), temporary);
  renameSync(temporary, layout.currentLink);
}

export function readPending(layout: RuntimeLayout): PendingUpdate | undefined {
  try {
    const parsed = JSON.parse(readFileSync(layout.pendingFile, "utf8")) as Partial<PendingUpdate>;
    return typeof parsed.version === "string"
      ? { version: parsed.version, attempts: typeof parsed.attempts === "number" ? parsed.attempts : 0, startedAt: parsed.startedAt ?? "", ...(parsed.previous ? { previous: parsed.previous } : {}) }
      : undefined;
  } catch {
    return undefined;
  }
}

export function writePending(layout: RuntimeLayout, pending: PendingUpdate): void {
  mkdirSync(layout.root, { recursive: true });
  writeFileSync(layout.pendingFile, `${JSON.stringify(pending, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
}

export function clearPending(layout: RuntimeLayout): void {
  try {
    unlinkSync(layout.pendingFile);
  } catch {
    // Already gone.
  }
}

/** Removes every installed version except the ones named. */
export function pruneVersions(layout: RuntimeLayout, keep: string[]): string[] {
  if (!existsSync(layout.versionsDir)) return [];
  const removed: string[] = [];
  for (const entry of readdirSync(layout.versionsDir)) {
    if (keep.includes(entry)) continue;
    rmSync(path.join(layout.versionsDir, entry), { recursive: true, force: true });
    removed.push(entry);
  }
  return removed;
}

export function writeLauncher(layout: RuntimeLayout): string {
  mkdirSync(layout.root, { recursive: true });
  writeFileSync(layout.launcher, LAUNCHER_SOURCE, { encoding: "utf8", mode: 0o600 });
  return layout.launcher;
}

// Plain ESM with no dependencies, so it loads even when a bad version cannot.
export const LAUNCHER_SOURCE = `// Tavi launcher — written by tavi-host, do not edit. Starts the current
// version and rolls back to the previous one if a fresh update keeps failing.
import { readFileSync, writeFileSync, symlinkSync, renameSync, unlinkSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
const pendingFile = path.join(root, "pending-update.json");
const currentLink = path.join(root, "current");
const MAX_ATTEMPTS = ${MAX_START_ATTEMPTS};

let pending;
try {
  pending = JSON.parse(readFileSync(pendingFile, "utf8"));
} catch {
  pending = undefined;
}
if (pending && typeof pending.version === "string") {
  pending.attempts = (pending.attempts || 0) + 1;
  if (pending.attempts > MAX_ATTEMPTS && pending.previous) {
    const temporary = currentLink + ".rollback";
    try { unlinkSync(temporary); } catch {}
    symlinkSync(path.join("versions", pending.previous), temporary);
    renameSync(temporary, currentLink);
    try { unlinkSync(pendingFile); } catch {}
    console.error("[tavi] " + pending.version + " failed to start " + MAX_ATTEMPTS + " times; rolled back to " + pending.previous);
  } else {
    writeFileSync(pendingFile, JSON.stringify(pending));
  }
}

await import(pathToFileURL(path.join(currentLink, "node_modules", "tavi-host", "dist", "index.js")).href);
`;
