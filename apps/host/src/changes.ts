import { execFile } from "node:child_process";
import path from "node:path";
import { promisify } from "node:util";
import { looksLikeASecret } from "./files.js";

// "What did it change" (#25): an agent's uncommitted work as git sees it,
// read-only. Three fixed git invocations — status, numstat, and one diff —
// run with execFile (no shell), a timeout, and an output cap. No mutating
// git operation exists on this path, by construction.

const execFileAsync = promisify(execFile);
const GIT_TIMEOUT_MS = 8_000;
// One file's diff over this is cut and marked; the phone says so.
export const MAX_DIFF_BYTES = 256 * 1024;
const MAX_CHANGED_FILES = 500;

export interface ChangedFile {
  // Relative to the repository root, as git prints it.
  path: string;
  // Git's two-letter porcelain code, e.g. " M", "M ", "??", "A ", "D ", "R ".
  code: string;
  // A word for the phone: modified / added / deleted / renamed / untracked / conflict.
  state: "modified" | "added" | "deleted" | "renamed" | "untracked" | "conflict" | "other";
  // Staged, unstaged, or both.
  staged: boolean;
  unstaged: boolean;
  additions?: number;
  deletions?: number;
  // The old path of a rename.
  from?: string;
  // Refused by the redaction rule: listed, never diffed.
  secret: boolean;
}

export type ChangesResult =
  | { ok: true; repository: string; branch: string | undefined; files: ChangedFile[]; truncated: boolean }
  | { ok: false; status: 400 | 404 | 503; error: string; notRepository?: true };

export async function listChanges(cwd: string): Promise<ChangesResult> {
  const repository = await repositoryRoot(cwd);
  if (!repository.ok) return repository;
  let statusOut: string;
  try {
    statusOut = (await git(repository.path, ["status", "--porcelain=v1", "-z", "--untracked-files=all"])).stdout;
  } catch (error) {
    return { ok: false, status: 503, error: `git status failed: ${describe(error)}` };
  }
  const files = parsePorcelain(statusOut);
  const numstat = await numstats(repository.path);
  for (const file of files) {
    const counts = numstat.get(file.path);
    if (counts) {
      file.additions = counts.additions;
      file.deletions = counts.deletions;
    }
  }
  return {
    ok: true,
    repository: repository.path,
    branch: await branchName(repository.path),
    files: files.slice(0, MAX_CHANGED_FILES),
    truncated: files.length > MAX_CHANGED_FILES,
  };
}

export interface FileDiff {
  path: string;
  // Unified diff text, as git prints it; empty for a deleted binary etc.
  diff: string;
  truncated: boolean;
  binary: boolean;
}

export type FileDiffResult =
  | { ok: true; diff: FileDiff }
  | { ok: false; status: 400 | 403 | 404 | 503; error: string };

// One file's working-tree change against HEAD: staged and unstaged in one
// view, untracked files as an all-additions diff. `relativePath` is what
// `listChanges` returned; anything that walks out of the repository is
// refused before git sees it.
export async function diffFile(cwd: string, relativePath: string): Promise<FileDiffResult> {
  const repository = await repositoryRoot(cwd);
  if (!repository.ok) return repository;
  const normalized = path.posix.normalize(relativePath.replaceAll("\\", "/"));
  if (!normalized || normalized.startsWith("../") || normalized === ".." || path.isAbsolute(normalized)) {
    return { ok: false, status: 400, error: "path must be relative to the repository." };
  }
  if (looksLikeASecret(normalized)) {
    return { ok: false, status: 403, error: "This file looks like it holds credentials, so Tavi does not show its changes." };
  }
  try {
    // Tracked (staged and/or unstaged): one diff against HEAD.
    const tracked = await git(repository.path, ["diff", "HEAD", "--", normalized], MAX_DIFF_BYTES + 1);
    if (tracked.stdout.length > 0) return { ok: true, diff: shape(normalized, tracked.stdout) };
  } catch (error) {
    // A fresh repository has no HEAD yet; fall through to the untracked view.
    if (!/bad revision|unknown revision|ambiguous argument 'HEAD'/i.test(describe(error))) {
      return { ok: false, status: 503, error: `git diff failed: ${describe(error)}` };
    }
  }
  try {
    // Untracked (or a brand-new repository): everything is an addition.
    const untracked = await git(
      repository.path,
      ["diff", "--no-index", "--", "/dev/null", normalized],
      MAX_DIFF_BYTES + 1,
      [0, 1],
    );
    if (untracked.stdout.length > 0) return { ok: true, diff: shape(normalized, untracked.stdout) };
  } catch (error) {
    if (/No such file|does not exist|cannot stat/i.test(describe(error))) {
      return { ok: false, status: 404, error: "No such file in the repository." };
    }
    return { ok: false, status: 503, error: `git diff failed: ${describe(error)}` };
  }
  return { ok: true, diff: { path: normalized, diff: "", truncated: false, binary: false } };
}

function shape(filePath: string, raw: string): FileDiff {
  const truncated = raw.length > MAX_DIFF_BYTES;
  let diff = truncated ? raw.slice(0, MAX_DIFF_BYTES) : raw;
  if (truncated) diff = diff.slice(0, Math.max(0, diff.lastIndexOf("\n")));
  return { path: filePath, diff, truncated, binary: /^Binary files .* differ$/m.test(raw) };
}

type RootResult = { ok: true; path: string } | { ok: false; status: 400 | 404; error: string; notRepository?: true };

async function repositoryRoot(cwd: string): Promise<RootResult> {
  if (!path.isAbsolute(cwd)) return { ok: false, status: 400, error: "cwd must be an absolute path." };
  try {
    const { stdout } = await git(cwd, ["rev-parse", "--show-toplevel"]);
    const root = stdout.trim();
    if (!root) return { ok: false, status: 404, error: "This folder is not inside a git repository.", notRepository: true };
    return { ok: true, path: root };
  } catch (error) {
    const message = describe(error);
    if (/not a git repository/i.test(message)) {
      return { ok: false, status: 404, error: "This folder is not inside a git repository.", notRepository: true };
    }
    if (/ENOENT/.test(message) && /git/.test(message)) {
      return { ok: false, status: 404, error: "git is not installed on this computer.", notRepository: true };
    }
    return { ok: false, status: 404, error: `This folder cannot be read as a git repository: ${message}`, notRepository: true };
  }
}

async function branchName(repository: string): Promise<string | undefined> {
  try {
    const { stdout } = await git(repository, ["rev-parse", "--abbrev-ref", "HEAD"]);
    const name = stdout.trim();
    return name && name !== "HEAD" ? name : undefined;
  } catch {
    return undefined;
  }
}

// `git status --porcelain=v1 -z`: "XY path\0" entries, renames as
// "XY new\0old\0". Order is git's (alphabetical within the tree).
export function parsePorcelain(raw: string): ChangedFile[] {
  const parts = raw.split("\0");
  const files: ChangedFile[] = [];
  for (let index = 0; index < parts.length; index += 1) {
    const entry = parts[index];
    if (!entry || entry.length < 4) continue;
    const code = entry.slice(0, 2);
    const filePath = entry.slice(3);
    let from: string | undefined;
    if (code[0] === "R" || code[0] === "C" || code[1] === "R" || code[1] === "C") {
      index += 1;
      from = parts[index];
    }
    const [x, y] = [code[0] ?? " ", code[1] ?? " "];
    let state: ChangedFile["state"] = "other";
    if (code === "??") state = "untracked";
    else if (x === "U" || y === "U" || code === "AA" || code === "DD") state = "conflict";
    else if (x === "R" || y === "R") state = "renamed";
    else if (x === "A" || y === "A") state = "added";
    else if (x === "D" || y === "D") state = "deleted";
    else if (x === "M" || y === "M" || x === "T" || y === "T") state = "modified";
    files.push({
      path: filePath,
      code,
      state,
      staged: code !== "??" && x !== " " && x !== "?",
      unstaged: code === "??" || (y !== " " && y !== "?"),
      ...(from ? { from } : {}),
      secret: looksLikeASecret(filePath),
    });
  }
  return files;
}

// Additions and deletions per path, working tree vs HEAD, so the list can
// say "+12 −3". Binary files report "-" and are left without counts.
async function numstats(repository: string): Promise<Map<string, { additions: number; deletions: number }>> {
  const result = new Map<string, { additions: number; deletions: number }>();
  try {
    const { stdout } = await git(repository, ["diff", "HEAD", "--numstat", "-z"]);
    // -z: "adds\tdels\tpath\0" (renames: "adds\tdels\t\0old\0new\0").
    const parts = stdout.split("\0");
    for (let index = 0; index < parts.length; index += 1) {
      const entry = parts[index];
      if (!entry) continue;
      const [adds, dels, filePath] = entry.split("\t");
      let target = filePath;
      if (target === "") {
        index += 2;
        target = parts[index];
      }
      if (!target) continue;
      const additions = Number.parseInt(adds ?? "", 10);
      const deletions = Number.parseInt(dels ?? "", 10);
      if (Number.isFinite(additions) && Number.isFinite(deletions)) result.set(target, { additions, deletions });
    }
  } catch {
    // No HEAD yet, or git unhappy: the list still stands without counts.
  }
  return result;
}

async function git(
  cwd: string,
  args: string[],
  maxBuffer = 4 * 1024 * 1024,
  okExitCodes: number[] = [0],
): Promise<{ stdout: string }> {
  try {
    const { stdout } = await execFileAsync("git", ["-C", cwd, ...args], {
      timeout: GIT_TIMEOUT_MS,
      maxBuffer,
      encoding: "utf8",
      env: { ...process.env, GIT_OPTIONAL_LOCKS: "0", GIT_TERMINAL_PROMPT: "0" },
    });
    return { stdout };
  } catch (error) {
    const code = (error as { code?: unknown }).code;
    const stdout = (error as { stdout?: string }).stdout;
    // `git diff` exits 1 when there is a difference; that is an answer.
    if (typeof code === "number" && okExitCodes.includes(code) && typeof stdout === "string") return { stdout };
    // Output beyond maxBuffer: what git managed to print is still the
    // start of the diff, and the caller marks it truncated.
    if (code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER" && typeof stdout === "string") return { stdout };
    throw error;
  }
}

function describe(error: unknown): string {
  const stderr = (error as { stderr?: string }).stderr;
  if (typeof stderr === "string" && stderr.trim()) return stderr.trim();
  return error instanceof Error ? error.message : String(error);
}
