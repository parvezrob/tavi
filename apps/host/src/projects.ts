import { statSync } from "node:fs";
import { log } from "./log.js";
import { readStateFile, writeStateFile } from "./state-file.js";
import path from "node:path";

// Where a phone-created agent is allowed to be born (#24). Agents used to
// land in the host user's home directory because `cwd` was optional; the
// picker now makes the folder an explicit choice, and this module owns the
// two halves that choice needs: the list the phone offers, and the rule the
// host enforces before it launches anything.

const HISTORY_FILE_NAME = "projects.json";
// Bump when the stored shape changes; an unrecognized version reads as empty
// rather than being reinterpreted as the current one.
const HISTORY_SCHEMA_VERSION = 1;
// A picker list, not an archive: enough to cover the handful of repos a
// person actually moves between.
const MAX_REMEMBERED = 12;
const MAX_PATH_CHARACTERS = 1_024;

export interface RecentProject {
  path: string;
  name: string;
  // ISO 8601. Absent for a directory that is only known because an agent is
  // running there right now — the host never invents a history it lacks.
  lastUsedAt?: string;
  // An agent currently lives here.
  active: boolean;
  // Inside a configured root, so creating here needs no extra confirmation.
  withinRoots: boolean;
}

interface StoredProject {
  path: string;
  lastUsedAt: string;
}

// A candidate `cwd` is only usable if it is an absolute path to a real
// directory. Returns the normalized path, or a reason the caller can hand
// straight to the client.
export type ProjectPathCheck = { ok: true; path: string } | { ok: false; reason: string };

export function normalizeProjectPath(value: string): ProjectPathCheck {
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > MAX_PATH_CHARACTERS || trimmed.includes("\0")) {
    return { ok: false, reason: "cwd must be an absolute path." };
  }
  if (!path.isAbsolute(trimmed)) return { ok: false, reason: "cwd must be an absolute path." };
  const resolved = path.resolve(trimmed);
  try {
    if (!statSync(resolved).isDirectory()) {
      return { ok: false, reason: "cwd must be a directory that exists on this Mac." };
    }
  } catch {
    // Missing, or a path we cannot stat: the same answer either way, and
    // the sentence is the one a person can act on.
    return { ok: false, reason: "cwd must be a directory that exists on this Mac." };
  }
  return { ok: true, path: resolved };
}

// macOS filesystems are normally case-insensitive and store names in a
// different Unicode form than the phone's keyboard emits, so two spellings
// of one directory must compare equal. Paths are only ever *compared*
// through this key; the spelling the caller used is what gets stored and
// displayed. On a case-sensitive volume this over-merges two directories
// that differ only in case — a duplicate row in a picker, against a root
// that would otherwise reject every folder under it.
function comparisonKey(value: string): string {
  return path.resolve(value).normalize("NFC").toLowerCase();
}

// Lexical containment against the configured roots. This is a guardrail
// against an agent landing somewhere nobody meant, not a security boundary:
// the pairing token already grants shell access, so a symlink that points
// out of a root is not a privilege the caller lacked anyway.
export function isWithinRoots(candidate: string, roots: readonly string[]): boolean {
  const resolved = comparisonKey(candidate);
  return roots.some((root) => {
    const base = comparisonKey(root);
    if (resolved === base) return true;
    return resolved.startsWith(base.endsWith(path.sep) ? base : `${base}${path.sep}`);
  });
}

// The most-recently-used folders behind the picker, persisted under the
// host state directory so the list survives restarts. A picker is never
// worth failing a request over, so every failure here degrades to an empty
// list — but it says so on the host log rather than vanishing silently.
export class ProjectHistory {
  constructor(
    private readonly stateDir: string,
    private readonly now: () => Date = () => new Date(),
    private readonly report: (message: string) => void = (message) => log.error("projects", message),
  ) {}

  list(): StoredProject[] {
    const read = readStateFile(this.file);
    if (read.status === "missing") return [];
    if (read.status === "unreadable") {
      this.report(`Tavi could not read the recent-projects list (${this.file}): ${read.reason}`);
      return [];
    }
    const parsed = read.value;

    const stored = parsed as { version?: unknown; recent?: unknown };
    if (stored?.version !== HISTORY_SCHEMA_VERSION) {
      this.report(
        `Ignoring a recent-projects list written by another version (${this.file}): expected version ${HISTORY_SCHEMA_VERSION}.`,
      );
      return [];
    }
    if (!Array.isArray(stored.recent)) {
      this.report(`Ignoring a malformed recent-projects list (${this.file}).`);
      return [];
    }

    return stored.recent
      .filter(
        (entry): entry is StoredProject =>
          typeof entry === "object" &&
          entry !== null &&
          typeof (entry as StoredProject).path === "string" &&
          // A stored relative path would resolve against whatever directory
          // the host happens to be running in.
          path.isAbsolute((entry as StoredProject).path) &&
          typeof (entry as StoredProject).lastUsedAt === "string",
      )
      .slice(0, MAX_REMEMBERED);
  }

  remember(directory: string): void {
    const resolved = path.resolve(directory);
    const key = comparisonKey(resolved);
    const kept = this.list().filter((entry) => comparisonKey(entry.path) !== key);
    const recent: StoredProject[] = [{ path: resolved, lastUsedAt: this.now().toISOString() }, ...kept].slice(
      0,
      MAX_REMEMBERED,
    );
    this.write(recent);
  }

  // A folder that no longer exists (a removed worktree, #81) leaves the
  // recent list rather than offering a dead choice.
  forget(directory: string): void {
    const key = comparisonKey(path.resolve(directory));
    const kept = this.list().filter((entry) => comparisonKey(entry.path) !== key);
    if (kept.length !== this.list().length) this.write(kept);
  }

  private get file(): string {
    return path.join(this.stateDir, HISTORY_FILE_NAME);
  }

  private write(recent: StoredProject[]): void {
    try {
      writeStateFile(this.file, { version: HISTORY_SCHEMA_VERSION, recent });
    } catch (error) {
      this.report(
        `Tavi could not save the recent-projects list (${this.file}): ${describe(error)}. The agent still started.`,
      );
    }
  }
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

// The picker's "Recent" list: folders an agent is running in right now,
// merged with what this host remembers. Active folders lead, then the most
// recently chosen. A remembered folder that has since been deleted is
// dropped rather than offered — starting an agent there would only fail.
export function mergeRecentProjects(
  remembered: readonly StoredProject[],
  agentCwds: readonly string[],
  roots: readonly string[],
): RecentProject[] {
  const byKey = new Map<string, RecentProject>();

  for (const entry of remembered) {
    const resolved = path.resolve(entry.path);
    const key = comparisonKey(resolved);
    if (byKey.has(key) || !isExistingDirectory(resolved)) continue;
    byKey.set(key, {
      path: resolved,
      name: path.basename(resolved),
      lastUsedAt: entry.lastUsedAt,
      active: false,
      withinRoots: isWithinRoots(resolved, roots),
    });
  }

  // A live agent's folder is offered even if it cannot be stat'd from here:
  // herdr says something is running in it, and that is the better authority.
  for (const cwd of agentCwds) {
    if (!cwd) continue;
    const resolved = path.resolve(cwd);
    const key = comparisonKey(resolved);
    const existing = byKey.get(key);
    if (existing) {
      existing.active = true;
      continue;
    }
    byKey.set(key, {
      path: resolved,
      name: path.basename(resolved),
      active: true,
      withinRoots: isWithinRoots(resolved, roots),
    });
  }

  return [...byKey.values()].sort((a, b) => {
    if (a.active !== b.active) return a.active ? -1 : 1;
    const left = a.lastUsedAt ?? "";
    const right = b.lastUsedAt ?? "";
    if (left !== right) return left < right ? 1 : -1;
    return a.name.localeCompare(b.name);
  });
}

function isExistingDirectory(candidate: string): boolean {
  try {
    return statSync(candidate).isDirectory();
  } catch {
    // A remembered folder that has been deleted or moved is simply not
    // there any more; the list drops it.
    return false;
  }
}
