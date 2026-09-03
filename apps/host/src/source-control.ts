import path from "node:path";
import { listChanges, type ChangedFile } from "./changes.js";
import { describeGitError, git } from "./git-exec.js";
import { aheadBehind, baseBranch } from "./git-refs.js";

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
  // Why ahead/behind could not be measured, as a sentence (#98). Absent
  // when they were: a git failure must not render as "in sync".
  aheadBehindFailed?: string;
  files: ChangedFile[];
  staged: number;
  truncated: boolean;
}

export type StatusResult =
  | { ok: true; status: WorktreeStatus }
  | { ok: false; status: 400 | 404 | 503; error: string; notRepository?: true };

export async function worktreeStatus(worktreePath: string): Promise<StatusResult> {
  const changes = await listChanges(worktreePath);
  if (!changes.ok)
    return {
      ok: false,
      status: changes.status,
      error: changes.error,
      ...(changes.notRepository ? { notRepository: true as const } : {}),
    };
  const branch = changes.branch ?? null;
  const base = await baseBranch(worktreePath, branch);
  const distance = await aheadBehind(worktreePath, branch, base);
  return {
    ok: true,
    status: {
      path: worktreePath,
      branch,
      base,
      // The zeros stay beside the reason so a phone built against 0.1.17,
      // which decodes `ahead`/`behind` as required numbers, keeps working.
      ahead: distance.ok ? distance.ahead : 0,
      behind: distance.ok ? distance.behind : 0,
      ...(distance.ok ? {} : { aheadBehindFailed: distance.error }),
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
export async function stageFiles(
  worktreePath: string,
  files: string[] | "all",
  direction: "stage" | "unstage",
): Promise<StageResult> {
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
    // Paths are repository-relative (as `status` lists them), so git runs
    // at the top level even when the phone named a subfolder.
    const top = (await git(worktreePath, ["rev-parse", "--show-toplevel"])).stdout.trim() || worktreePath;
    if (direction === "stage") {
      await git(top, ["add", "--", ...targets]);
    } else {
      await git(top, ["restore", "--staged", "--", ...targets]);
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
  const staged = await stagedPaths(worktreePath);
  if (!staged.ok) return staged;
  const stagedFiles = staged.paths;
  if (stagedFiles.length === 0)
    return { ok: false, status: 409, error: "Nothing is staged. Stage a file, then commit." };
  try {
    await git(worktreePath, ["commit", "--quiet", "-m", trimmed]);
  } catch (error) {
    const reason = describeGitError(error);
    if (/Please tell me who you are|Author identity unknown|empty ident/i.test(reason)) {
      return {
        ok: false,
        status: 409,
        error:
          "git does not know who you are on this computer. Set user.name and user.email in git config there, then commit again.",
      };
    }
    return { ok: false, status: 503, error: `git could not commit: ${reason}` };
  }
  try {
    const { stdout } = await git(worktreePath, ["log", "-1", "--format=%H%n%s"]);
    const [sha = "", summary = ""] = stdout.split("\n");
    return { ok: true, commit: { sha, summary, files: stagedFiles.length } };
  } catch {
    // The commit is made; only its sha could not be read back, and the
    // summary the person typed is the one the commit carries.
    return { ok: true, commit: { sha: "", summary: trimmed.split("\n")[0] ?? trimmed, files: stagedFiles.length } };
  }
}

export type StagedPaths = { ok: true; paths: string[] } | { ok: false; status: 503; error: string };

// What `diff --cached` lists, or why it could not be read. Never an empty
// list on failure (#98): "Nothing is staged" is a fact about the index that
// sends a person back to stage files they already staged, and a commit
// route that believed it would refuse a commit that should have happened.
export async function stagedPaths(worktreePath: string): Promise<StagedPaths> {
  try {
    const { stdout } = await git(worktreePath, ["diff", "--cached", "--name-only", "-z"]);
    return { ok: true, paths: stdout.split("\0").filter((entry) => entry.length > 0) };
  } catch (error) {
    return { ok: false, status: 503, error: `git could not read what is staged: ${describeGitError(error)}` };
  }
}

function normalizeRelative(file: string): string | null {
  const normalized = path.posix.normalize(file.replaceAll("\\", "/"));
  if (
    !normalized ||
    normalized === "." ||
    normalized === ".." ||
    normalized.startsWith("../") ||
    path.isAbsolute(normalized) ||
    normalized.includes("\0")
  ) {
    return null;
  }
  return normalized;
}
