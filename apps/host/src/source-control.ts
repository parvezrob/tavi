import { execFile, spawn } from "node:child_process";
import path from "node:path";
import { listChanges, type ChangedFile } from "./changes.js";
import { looksLikeASecret } from "./files.js";
import { describeGitError, git } from "./git-exec.js";
import { findDefaultBranch, refExists } from "./git.js";

// Source Control — Changes (#77, #73 part 3; PRD §7.12): one worktree's
// changed files, staging, and committing, from the phone. The first git
// *writes* to a working tree this host makes beyond creating a worktree,
// and each is a fixed argv `execFile` with paths validated the way
// `diffFile` validates them. Every route takes the worktree's own path,
// realpath'd and checked against the roots by the caller.

export interface WorktreeStatus {
  path: string;
  branch: string | null;
  // What "ahead/behind" is measured against: `branch.<b>.base` when the
  // worktree was made by Tavi (or set by hand), else the repo's default.
  base: string | null;
  ahead: number;
  behind: number;
  files: ChangedFile[];
  staged: number;
  truncated: boolean;
}

export type StatusResult =
  | { ok: true; status: WorktreeStatus }
  | { ok: false; status: 400 | 404 | 503; error: string };

export async function worktreeStatus(worktreePath: string): Promise<StatusResult> {
  const changes = await listChanges(worktreePath);
  if (!changes.ok) return { ok: false, status: changes.status, error: changes.error };
  const branch = changes.branch ?? null;
  const base = await baseBranch(worktreePath, branch);
  const [ahead, behind] = await aheadBehind(worktreePath, branch, base);
  return {
    ok: true,
    status: {
      path: worktreePath,
      branch,
      base,
      ahead,
      behind,
      files: changes.files,
      staged: changes.files.filter((file) => file.staged).length,
      truncated: changes.truncated,
    },
  };
}

export type StageResult = { ok: true; staged: number } | { ok: false; status: 400 | 404 | 503; error: string };

// `files: "all"` stages (or unstages) everything git status lists. A path
// is relative to the repository and may not leave it — the same rule the
// diff route enforces before git sees a path.
export async function stageFiles(worktreePath: string, files: string[] | "all", direction: "stage" | "unstage"): Promise<StageResult> {
  let targets: string[];
  if (files === "all") {
    const changes = await listChanges(worktreePath);
    if (!changes.ok) return { ok: false, status: changes.status, error: changes.error };
    targets = changes.files.map((file) => file.path);
  } else {
    targets = [];
    for (const file of files) {
      const normalized = normalizeRelative(file);
      if (!normalized) return { ok: false, status: 400, error: `"${file}" is not a path inside the repository.` };
      targets.push(normalized);
    }
  }
  if (targets.length === 0) return { ok: true, staged: 0 };
  try {
    if (direction === "stage") {
      await git(worktreePath, ["add", "--", ...targets]);
    } else {
      await git(worktreePath, ["restore", "--staged", "--", ...targets]);
    }
    return { ok: true, staged: targets.length };
  } catch (error) {
    return { ok: false, status: 503, error: `git could not ${direction} that: ${describeGitError(error)}` };
  }
}

export interface CommitInfo {
  sha: string;
  summary: string;
  files: number;
}

export type CommitResult = { ok: true; commit: CommitInfo } | { ok: false; status: 400 | 409 | 503; error: string };

const MAX_MESSAGE_CHARACTERS = 4_000;

// Commits exactly what is staged. Nothing staged, an empty message, or a
// missing git identity each come back as a sentence, not a git error.
export async function commitStaged(worktreePath: string, message: string): Promise<CommitResult> {
  const trimmed = message.trim();
  if (!trimmed) return { ok: false, status: 400, error: "Write a commit message first." };
  if (trimmed.length > MAX_MESSAGE_CHARACTERS || trimmed.includes("\0")) {
    return { ok: false, status: 400, error: "That commit message is too long." };
  }
  const stagedFiles = await stagedPaths(worktreePath);
  if (stagedFiles.length === 0) return { ok: false, status: 409, error: "Nothing is staged. Stage a file, then commit." };
  try {
    await git(worktreePath, ["commit", "--quiet", "-m", trimmed]);
  } catch (error) {
    const reason = describeGitError(error);
    if (/Please tell me who you are|Author identity unknown|empty ident/i.test(reason)) {
      return { ok: false, status: 409, error: "git does not know who you are on this computer. Set user.name and user.email in git config there, then commit again." };
    }
    return { ok: false, status: 503, error: `git could not commit: ${reason}` };
  }
  try {
    const { stdout } = await git(worktreePath, ["log", "-1", "--format=%H%n%s"]);
    const [sha = "", summary = ""] = stdout.split("\n");
    return { ok: true, commit: { sha, summary, files: stagedFiles.length } };
  } catch {
    return { ok: true, commit: { sha: "", summary: trimmed.split("\n")[0] ?? trimmed, files: stagedFiles.length } };
  }
}

export type MessageResult = { ok: true; message: string } | { ok: false; status: 409 | 503; error: string };

export interface MessageWriterDeps {
  shell: string;
  // Runs the model with a prompt and stdin, returns its text. Injectable so
  // tests need no `claude`.
  runClaude?: (prompt: string, input: string) => Promise<string>;
}

const MAX_DIFF_FOR_MESSAGE = 200 * 1024;
const CLAUDE_TIMEOUT_MS = 45_000;
const MESSAGE_PROMPT =
  "Write a git commit message for the staged diff on stdin: one line in conventional-commit form " +
  "(type(scope): summary), at most 72 characters, imperative, no quotes, no trailing period, " +
  "then nothing else. Output only the message.";

// A one-line conventional message for the staged set, written by the
// `claude` CLI on this computer — the same login the terminals use — from
// the staged diff with secret-looking files left out by name. 409 when
// nothing is staged, 503 when claude is missing or says nothing.
export async function writeCommitMessage(worktreePath: string, deps: MessageWriterDeps): Promise<MessageResult> {
  const staged = await stagedPaths(worktreePath);
  if (staged.length === 0) return { ok: false, status: 409, error: "Nothing is staged. Stage a file first." };
  const shown = staged.filter((file) => !looksLikeASecret(file));
  let diff = "";
  if (shown.length > 0) {
    try {
      diff = (await git(worktreePath, ["diff", "--cached", "--", ...shown], MAX_DIFF_FOR_MESSAGE + 1)).stdout.slice(0, MAX_DIFF_FOR_MESSAGE);
    } catch (error) {
      return { ok: false, status: 503, error: `git could not read the staged diff: ${describeGitError(error)}` };
    }
  }
  const header = `Staged files: ${staged.join(", ")}\n\n`;
  try {
    const run = deps.runClaude ?? ((prompt, input) => runClaudeCli(deps.shell, prompt, input));
    const text = (await run(MESSAGE_PROMPT, header + diff)).trim().split("\n")[0]?.trim() ?? "";
    if (!text) return { ok: false, status: 503, error: "Claude did not write a message. Type one instead." };
    return { ok: true, message: text.slice(0, 200) };
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    if (/not installed|ENOENT|command not found/i.test(reason)) {
      return { ok: false, status: 503, error: "Claude Code is not installed on this computer, so it cannot write the message. Type one instead." };
    }
    return { ok: false, status: 503, error: `Claude could not write a message: ${reason}` };
  }
}

// `claude -p <prompt>` with the diff on stdin, resolved on the login-shell
// PATH the way agent kinds are (the launchd service's own PATH is bare).
async function runClaudeCli(shell: string, prompt: string, input: string): Promise<string> {
  const binary = await resolveOnLoginPath(shell, "claude");
  if (!binary) throw new Error("claude is not installed");
  return new Promise((resolve, reject) => {
    const child = spawn(binary, ["-p", prompt, "--output-format", "text"], {
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1" },
    });
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    const timer = setTimeout(() => child.kill(), CLAUDE_TIMEOUT_MS);
    child.stdout.on("data", (chunk: Buffer) => out.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => err.push(chunk));
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code === 0) resolve(Buffer.concat(out).toString("utf8"));
      else reject(new Error(Buffer.concat(err).toString("utf8").trim() || `claude exited with ${code}`));
    });
    child.stdin.on("error", () => undefined);
    child.stdin.end(input);
  });
}

function resolveOnLoginPath(shell: string, name: string): Promise<string | null> {
  return new Promise((resolve) => {
    execFile(shell, ["-lc", `command -v ${name}`], { timeout: 10_000 }, (error, stdout) => {
      const found = String(stdout ?? "").trim().split("\n").pop()?.trim() ?? "";
      resolve(!error && found.startsWith("/") ? found : null);
    });
  });
}

async function stagedPaths(worktreePath: string): Promise<string[]> {
  try {
    const { stdout } = await git(worktreePath, ["diff", "--cached", "--name-only", "-z"]);
    return stdout.split("\0").filter((entry) => entry.length > 0);
  } catch {
    return [];
  }
}

async function baseBranch(worktreePath: string, branch: string | null): Promise<string | null> {
  if (branch) {
    try {
      const configured = (await git(worktreePath, ["config", "--get", `branch.${branch}.base`])).stdout.trim();
      if (configured && (await refExists(worktreePath, configured))) return configured;
    } catch {
      // Not configured: fall through to the repository's default.
    }
  }
  const fallback = await findDefaultBranch(worktreePath);
  return fallback && fallback !== branch ? fallback : fallback;
}

async function aheadBehind(worktreePath: string, branch: string | null, base: string | null): Promise<[number, number]> {
  if (!branch || !base || branch === base) return [0, 0];
  try {
    const { stdout } = await git(worktreePath, ["rev-list", "--left-right", "--count", `${branch}...${base}`]);
    const [ahead, behind] = stdout.trim().split(/\s+/).map((value) => Number.parseInt(value, 10) || 0);
    return [ahead ?? 0, behind ?? 0];
  } catch {
    return [0, 0];
  }
}

function normalizeRelative(file: string): string | null {
  const normalized = path.posix.normalize(file.replaceAll("\\", "/"));
  if (!normalized || normalized === "." || normalized === ".." || normalized.startsWith("../") || path.isAbsolute(normalized) || normalized.includes("\0")) {
    return null;
  }
  return normalized;
}
