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

// MARK: Commits (#78, #73 part 4)

export interface CommitSummary {
  sha: string;
  summary: string;
  author: string;
  // ISO 8601 author date; the phone renders "12 min".
  when: string;
}

export interface UpstreamInfo {
  name: string;
  // Commits not yet pushed / not yet pulled, against the tracking ref.
  ahead: number;
  behind: number;
}

export interface WorktreeLog {
  path: string;
  branch: string | null;
  base: string | null;
  // Commits this branch has over the base, newest first, and the base's
  // over this branch — the two sections of the Commits tab.
  ahead: CommitSummary[];
  behind: CommitSummary[];
  upstream: UpstreamInfo | null;
  // Where a first push would go; null when the repository has no remote.
  remote: string | null;
  truncated: boolean;
}

export type LogResult = { ok: true; log: WorktreeLog } | { ok: false; status: 400 | 404 | 503; error: string };

const MAX_LOG_COMMITS = 100;

export async function worktreeLog(worktreePath: string): Promise<LogResult> {
  let branch: string | null;
  try {
    const { stdout } = await git(worktreePath, ["symbolic-ref", "--quiet", "--short", "HEAD"], undefined, [0, 1]);
    branch = stdout.trim() || null;
  } catch (error) {
    return { ok: false, status: 503, error: `git could not read that worktree: ${describeGitError(error)}` };
  }
  const base = await baseBranch(worktreePath, branch);
  const [ahead, behind] = await Promise.all([
    branch && base && branch !== base ? readLog(worktreePath, `${base}..${branch}`) : Promise.resolve({ commits: [], truncated: false }),
    branch && base && branch !== base ? readLog(worktreePath, `${branch}..${base}`) : Promise.resolve({ commits: [], truncated: false }),
  ]);
  const upstream = branch ? await upstreamInfo(worktreePath, branch) : null;
  const remote = branch ? await pushRemote(worktreePath, branch) : null;
  return {
    ok: true,
    log: {
      path: worktreePath,
      branch,
      base,
      ahead: ahead.commits,
      behind: behind.commits,
      upstream,
      remote,
      truncated: ahead.truncated || behind.truncated,
    },
  };
}

async function readLog(worktreePath: string, range: string): Promise<{ commits: CommitSummary[]; truncated: boolean }> {
  try {
    const { stdout } = await git(worktreePath, ["log", `--max-count=${MAX_LOG_COMMITS + 1}`, "--format=%H%x00%s%x00%an%x00%aI%x1e", range]);
    const commits: CommitSummary[] = [];
    for (const record of stdout.split("\x1e")) {
      const [sha = "", summary = "", author = "", when = ""] = record.replace(/^\n/, "").split("\0");
      if (/^[0-9a-f]{40}$/.test(sha)) commits.push({ sha, summary, author, when: when.trim() });
    }
    return { commits: commits.slice(0, MAX_LOG_COMMITS), truncated: commits.length > MAX_LOG_COMMITS };
  } catch {
    return { commits: [], truncated: false };
  }
}

async function upstreamInfo(worktreePath: string, branch: string): Promise<UpstreamInfo | null> {
  try {
    const name = (await git(worktreePath, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", `${branch}@{upstream}`])).stdout.trim();
    if (!name) return null;
    const { stdout } = await git(worktreePath, ["rev-list", "--left-right", "--count", `${branch}...${name}`]);
    const [ahead = 0, behind = 0] = stdout.trim().split(/\s+/).map((value) => Number.parseInt(value, 10) || 0);
    return { name, ahead, behind };
  } catch {
    // No upstream configured, or it was deleted on the remote.
    return null;
  }
}

// `branch.<b>.pushRemote` → `remote.pushDefault` → `origin` → the only
// remote there is. null when the repository has none.
async function pushRemote(worktreePath: string, branch: string): Promise<string | null> {
  let remotes: string[];
  try {
    remotes = (await git(worktreePath, ["remote"])).stdout.split("\n").map((line) => line.trim()).filter(Boolean);
  } catch {
    return null;
  }
  if (remotes.length === 0) return null;
  for (const key of [`branch.${branch}.pushRemote`, "remote.pushDefault"]) {
    try {
      const configured = (await git(worktreePath, ["config", "--get", key])).stdout.trim();
      if (configured && remotes.includes(configured)) return configured;
    } catch {
      // Not set.
    }
  }
  if (remotes.includes("origin")) return "origin";
  return remotes.length === 1 ? (remotes[0] ?? null) : null;
}

export type PushResult = { ok: true; pushed: number; upstream: string } | { ok: false; status: 409 | 503; error: string };

const PUSH_TIMEOUT_MS = 90_000;

// Pushes the branch: to its upstream when it has one, else to the push
// remote, setting the upstream on the way (the first push of a worktree
// Tavi did not create). Never `--force`; a rejected push is a sentence.
export async function pushBranch(worktreePath: string): Promise<PushResult> {
  let branch: string | null;
  try {
    branch = (await git(worktreePath, ["symbolic-ref", "--quiet", "--short", "HEAD"], undefined, [0, 1])).stdout.trim() || null;
  } catch (error) {
    return { ok: false, status: 503, error: `git could not read that worktree: ${describeGitError(error)}` };
  }
  if (!branch) return { ok: false, status: 409, error: "This worktree is not on a branch, so there is nothing to push." };
  const upstream = await upstreamInfo(worktreePath, branch);
  if (upstream && upstream.ahead === 0) {
    return { ok: false, status: 409, error: `${upstream.name} already has everything on ${branch}.` };
  }
  const remote = await pushRemote(worktreePath, branch);
  if (!upstream && !remote) {
    return { ok: false, status: 409, error: "This repository has no remote to push to. Add one on the computer (git remote add origin …), then push again." };
  }
  // What goes up: the commits the upstream lacks, or on a first push every
  // commit the branch has over its base.
  const pushed = upstream ? upstream.ahead : (await aheadBehind(worktreePath, branch, await baseBranch(worktreePath, branch)))[0];
  const args = upstream ? ["push", "--quiet", "--porcelain"] : ["push", "--quiet", "--porcelain", "--set-upstream", remote as string, branch];
  try {
    await git(worktreePath, args, undefined, [0], PUSH_TIMEOUT_MS);
  } catch (error) {
    const reason = describeGitError(error);
    if (/non-fast-forward|fetch first|rejected/i.test(reason)) {
      return { ok: false, status: 409, error: `${upstream?.name ?? remote} has commits this branch does not. Pull them in on the computer first, then push again.` };
    }
    if (/Permission denied|Authentication failed|could not read Username|publickey|403/i.test(reason)) {
      return { ok: false, status: 503, error: `The remote refused the push: git on the computer is not signed in to it. (${firstLine(reason)})` };
    }
    if (/Could not resolve host|Connection timed out|Network is unreachable|ETIMEDOUT|SIGTERM/i.test(reason)) {
      return { ok: false, status: 503, error: `The remote could not be reached from the computer. (${firstLine(reason)})` };
    }
    return { ok: false, status: 503, error: `git could not push: ${firstLine(reason)}` };
  }
  const after = await upstreamInfo(worktreePath, branch);
  return { ok: true, pushed, upstream: after?.name ?? `${remote}/${branch}` };
}

export type PullBaseResult =
  | { ok: true; merged: number; fastForward: boolean; sha: string }
  | { ok: false; status: 409 | 503; error: string };

// Merges the (local) base branch into the worktree with a merge commit or a
// fast-forward. A conflict is aborted before anyone sees it, and named.
export async function pullBase(worktreePath: string): Promise<PullBaseResult> {
  let branch: string | null;
  try {
    branch = (await git(worktreePath, ["symbolic-ref", "--quiet", "--short", "HEAD"], undefined, [0, 1])).stdout.trim() || null;
  } catch (error) {
    return { ok: false, status: 503, error: `git could not read that worktree: ${describeGitError(error)}` };
  }
  if (!branch) return { ok: false, status: 409, error: "This worktree is not on a branch, so there is nothing to merge into." };
  const base = await baseBranch(worktreePath, branch);
  if (!base || base === branch) return { ok: false, status: 409, error: "This branch has no base branch to pull in." };
  const [, behind] = await aheadBehind(worktreePath, branch, base);
  if (behind === 0) {
    const sha = await headSha(worktreePath);
    return { ok: true, merged: 0, fastForward: false, sha };
  }
  try {
    await git(worktreePath, ["merge", "--quiet", "--no-edit", "--no-stat", base], undefined, [0], 30_000);
  } catch (error) {
    const reason = describeGitError(error);
    if (/would be overwritten|uncommitted changes|unmerged files|not possible because you have/i.test(reason)) {
      return { ok: false, status: 409, error: `Uncommitted changes on ${branch} would be overwritten by ${base}. Commit or stash them first.` };
    }
    const conflicts = await conflictedFiles(worktreePath);
    if (conflicts.length > 0 || /CONFLICT|Automatic merge failed/i.test(reason)) {
      try {
        await git(worktreePath, ["merge", "--abort"]);
      } catch {
        // Nothing to abort: git refused before starting.
      }
      const named = conflicts.slice(0, 5).join(", ") + (conflicts.length > 5 ? ` and ${conflicts.length - 5} more` : "");
      return { ok: false, status: 409, error: `${base} conflicts with ${branch}${named ? ` in ${named}` : ""}. Resolve that on the computer; nothing was changed here.` };
    }
    return { ok: false, status: 503, error: `git could not merge ${base}: ${firstLine(reason)}` };
  }
  const sha = await headSha(worktreePath);
  let fastForward = false;
  try {
    const parents = (await git(worktreePath, ["rev-list", "--parents", "-n", "1", "HEAD"])).stdout.trim().split(/\s+/);
    fastForward = parents.length <= 2;
  } catch {
    // Reported as a merge; the count is what matters.
  }
  return { ok: true, merged: behind, fastForward, sha };
}

async function conflictedFiles(worktreePath: string): Promise<string[]> {
  try {
    const { stdout } = await git(worktreePath, ["diff", "--name-only", "--diff-filter=U", "-z"]);
    return stdout.split("\0").filter((entry) => entry.length > 0);
  } catch {
    return [];
  }
}

async function headSha(worktreePath: string): Promise<string> {
  try {
    return (await git(worktreePath, ["rev-parse", "HEAD"])).stdout.trim();
  } catch {
    return "";
  }
}

function firstLine(text: string): string {
  return text.split("\n").map((line) => line.trim()).filter((line) => line && !/^(To |remote: *$|!\s)/.test(line))[0] ?? text.trim();
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
