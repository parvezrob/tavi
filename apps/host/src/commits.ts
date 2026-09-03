import { describeGitError, git } from "./git-exec.js";
import { aheadBehind, baseBranch, currentBranch, pushRemote, type UpstreamInfo, upstreamInfo } from "./git-refs.js";

// Source Control — Commits (#78, #73 part 4; PRD §7.12): the branch's
// commits over and under its base, Push, and Pull main in. Split out of
// source-control.ts in #98 along the divider that file already carried;
// Changes (status, staging, committing) is the sibling module.

export interface CommitSummary {
  sha: string;
  summary: string;
  author: string;
  // ISO 8601 author date; the phone renders "12 min".
  when: string;
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
    branch = await currentBranch(worktreePath);
  } catch (error) {
    return { ok: false, status: 503, error: `git could not read that worktree: ${describeGitError(error)}` };
  }
  const base = await baseBranch(worktreePath, branch);
  const [ahead, behind] = await Promise.all([
    branch && base && branch !== base
      ? readLog(worktreePath, `${base}..${branch}`)
      : Promise.resolve({ commits: [], truncated: false }),
    branch && base && branch !== base
      ? readLog(worktreePath, `${branch}..${base}`)
      : Promise.resolve({ commits: [], truncated: false }),
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
    const { stdout } = await git(worktreePath, [
      "log",
      `--max-count=${MAX_LOG_COMMITS + 1}`,
      "--format=%H%x00%s%x00%an%x00%aI%x1e",
      range,
    ]);
    const commits: CommitSummary[] = [];
    for (const record of stdout.split("\x1e")) {
      const [sha = "", summary = "", author = "", when = ""] = record.replace(/^\n/, "").split("\0");
      if (/^[0-9a-f]{40}$/.test(sha)) commits.push({ sha, summary, author, when: when.trim() });
    }
    return { commits: commits.slice(0, MAX_LOG_COMMITS), truncated: commits.length > MAX_LOG_COMMITS };
  } catch {
    // One of the two ranges may name a ref that does not resolve (a base
    // deleted on the remote); the other section still stands.
    return { commits: [], truncated: false };
  }
}

export type PushResult =
  | { ok: true; pushed: number; upstream: string }
  | { ok: false; status: 409 | 503; error: string };

const PUSH_TIMEOUT_MS = 90_000;

// Pushes the branch: to its upstream when it has one, else to the push
// remote, setting the upstream on the way (the first push of a worktree
// Tavi did not create). Never `--force`; a rejected push is a sentence.
export async function pushBranch(worktreePath: string): Promise<PushResult> {
  let branch: string | null;
  try {
    branch = await currentBranch(worktreePath);
  } catch (error) {
    return { ok: false, status: 503, error: `git could not read that worktree: ${describeGitError(error)}` };
  }
  if (!branch)
    return { ok: false, status: 409, error: "This worktree is not on a branch, so there is nothing to push." };
  const upstream = await upstreamInfo(worktreePath, branch);
  if (upstream && upstream.ahead === 0) {
    return { ok: false, status: 409, error: `${upstream.name} already has everything on ${branch}.` };
  }
  const remote = await pushRemote(worktreePath, branch);
  if (!upstream && !remote) {
    return {
      ok: false,
      status: 409,
      error:
        "This repository has no remote to push to. Add one on the computer (git remote add origin …), then push again.",
    };
  }
  // What goes up: the commits the upstream lacks, or on a first push every
  // commit the branch has over its base — a comparison git cannot make
  // costs the reported number, never the push itself.
  const overBase = upstream ? null : await aheadBehind(worktreePath, branch, await baseBranch(worktreePath, branch));
  const pushed = upstream ? upstream.ahead : overBase?.ok ? overBase.ahead : 0;
  // Always name the remote and the refspec: a bare `git push` obeys
  // `push.default`, and `matching` would publish every branch that has a
  // namesake on the remote (#81 review).
  const target = upstream ? await upstreamRemote(worktreePath, branch, remote) : (remote as string);
  const args = upstream
    ? ["push", "--quiet", "--porcelain", target, `HEAD:refs/heads/${upstreamBranch(upstream.name, target)}`]
    : ["push", "--quiet", "--porcelain", "--set-upstream", target, `${branch}:refs/heads/${branch}`];
  try {
    await git(worktreePath, args, undefined, [0], PUSH_TIMEOUT_MS);
  } catch (error) {
    const reason = describeGitError(error);
    if (/non-fast-forward|fetch first|rejected/i.test(reason)) {
      return {
        ok: false,
        status: 409,
        error: `${upstream?.name ?? remote} has commits this branch does not. Pull them in on the computer first, then push again.`,
      };
    }
    if (/Permission denied|Authentication failed|could not read Username|publickey|403/i.test(reason)) {
      return {
        ok: false,
        status: 503,
        error: `The remote refused the push: git on the computer is not signed in to it. (${firstLine(reason)})`,
      };
    }
    if (/Could not resolve host|Connection timed out|Network is unreachable|ETIMEDOUT|SIGTERM/i.test(reason)) {
      return {
        ok: false,
        status: 503,
        error: `The remote could not be reached from the computer. (${firstLine(reason)})`,
      };
    }
    return { ok: false, status: 503, error: `git could not push: ${firstLine(reason)}` };
  }
  const after = await upstreamInfo(worktreePath, branch);
  return { ok: true, pushed, upstream: after?.name ?? `${remote}/${branch}` };
}

// The remote the branch's upstream lives on (`branch.<b>.remote`), else the
// push remote; and the upstream's branch name without the remote prefix.
async function upstreamRemote(worktreePath: string, branch: string, fallback: string | null): Promise<string> {
  try {
    const configured = (await git(worktreePath, ["config", "--get", `branch.${branch}.remote`])).stdout.trim();
    if (configured && configured !== ".") return configured;
  } catch {
    // Not configured.
  }
  return fallback ?? "origin";
}

function upstreamBranch(upstreamName: string, remote: string): string {
  return upstreamName.startsWith(`${remote}/`) ? upstreamName.slice(remote.length + 1) : upstreamName;
}

export type PullBaseResult =
  | { ok: true; merged: number; fastForward: boolean; sha: string; fetched: boolean; from: string }
  | { ok: false; status: 409 | 503; error: string };

const FETCH_TIMEOUT_MS = 15_000;

// Merges the base branch into the worktree with a merge commit or a
// fast-forward. The base's upstream is fetched first, so "pull main in"
// means today's main, not the last fetch's (#83): the local base is moved
// up when it can be (behind its upstream and not checked out anywhere),
// else the fresh remote-tracking ref is what gets merged; when the fetch
// cannot happen (no upstream, offline, too slow) the local base is merged
// as it stands and `fetched` says so. A conflict is aborted before anyone
// sees it, and named.
export async function pullBase(worktreePath: string): Promise<PullBaseResult> {
  let branch: string | null;
  try {
    branch = await currentBranch(worktreePath);
  } catch (error) {
    return { ok: false, status: 503, error: `git could not read that worktree: ${describeGitError(error)}` };
  }
  if (!branch)
    return { ok: false, status: 409, error: "This worktree is not on a branch, so there is nothing to merge into." };
  const base = await baseBranch(worktreePath, branch);
  if (!base || base === branch) return { ok: false, status: 409, error: "This branch has no base branch to pull in." };
  const refreshed = await refreshBase(worktreePath, base);
  const from = refreshed.ref;
  const distance = await aheadBehind(worktreePath, branch, from);
  // "Nothing to bring in" is a measurement, not a default: a failed
  // comparison must never read as "already up to date" (#98).
  if (!distance.ok) {
    return { ok: false, status: 503, error: `git could not compare ${branch} with ${from}: ${distance.error}` };
  }
  const behind = distance.behind;
  if (behind === 0) {
    const sha = await headSha(worktreePath);
    return { ok: true, merged: 0, fastForward: false, sha, fetched: refreshed.fetched, from };
  }
  try {
    await git(worktreePath, ["merge", "--quiet", "--no-edit", "--no-stat", from], undefined, [0], 30_000);
  } catch (error) {
    const reason = describeGitError(error);
    if (/would be overwritten|uncommitted changes|unmerged files|not possible because you have/i.test(reason)) {
      return {
        ok: false,
        status: 409,
        error: `Uncommitted changes on ${branch} would be overwritten by ${base}. Commit or stash them first.`,
      };
    }
    const conflicts = await conflictedFiles(worktreePath);
    // Whatever stopped the merge — a conflict, a killed merge driver, the
    // budget — the tree is put back before anyone hears about it.
    let aborted = true;
    try {
      await git(worktreePath, ["merge", "--abort"]);
    } catch {
      // `merge --abort` refuses when there is nothing to abort; MERGE_HEAD
      // is the only trustworthy answer to whether the tree was put back.
      aborted = !(await mergeInProgress(worktreePath));
    }
    const restored = aborted
      ? "nothing was changed here"
      : "the merge is still half-done there — finish or abort it on the computer";
    if (conflicts.length > 0 || /CONFLICT|Automatic merge failed/i.test(reason)) {
      const named =
        conflicts.slice(0, 5).join(", ") + (conflicts.length > 5 ? ` and ${conflicts.length - 5} more` : "");
      return {
        ok: false,
        status: 409,
        error: `${base} conflicts with ${branch}${named ? ` in ${named}` : ""}. Resolve that on the computer; ${restored}.`,
      };
    }
    const killed =
      /SIGTERM|ETIMEDOUT/i.test(error instanceof Error ? error.message : "") && !/fatal:|error:/i.test(reason);
    if (killed) return { ok: false, status: 503, error: `Merging ${base} took too long and was stopped; ${restored}.` };
    return { ok: false, status: 503, error: `git could not merge ${base}: ${firstLine(reason)}; ${restored}.` };
  }
  const sha = await headSha(worktreePath);
  let fastForward = false;
  try {
    const parents = (await git(worktreePath, ["rev-list", "--parents", "-n", "1", "HEAD"])).stdout.trim().split(/\s+/);
    fastForward = parents.length <= 2;
  } catch {
    // Reported as a merge; the count is what matters.
  }
  return { ok: true, merged: behind, fastForward, sha, fetched: refreshed.fetched, from };
}

// The freshest ref for the base: its upstream fetched (best effort, one
// short budget, never a prompt), then the local branch fast-forwarded to
// it when git allows — `branch -f` refuses a branch checked out in any
// worktree, and the main checkout usually stands on the base — else the
// remote-tracking ref itself when the local base is merely behind it. A
// local base that has moved on its own (diverged) is the person's, and it
// is what gets merged.
async function refreshBase(worktreePath: string, base: string): Promise<{ ref: string; fetched: boolean }> {
  let upstream: string | null = null;
  try {
    upstream =
      (
        await git(worktreePath, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", `${base}@{upstream}`])
      ).stdout.trim() || null;
  } catch {
    // No upstream configured for the base: nothing to fetch, and the local
    // base is what gets merged (`fetched: false` says so).
    upstream = null;
  }
  if (!upstream) return { ref: base, fetched: false };
  const remote = upstream.split("/")[0] ?? "";
  const remoteBranch = upstream.slice(remote.length + 1);
  if (!remote || !remoteBranch) return { ref: base, fetched: false };
  try {
    await git(worktreePath, ["fetch", "--quiet", remote, remoteBranch], undefined, [0], FETCH_TIMEOUT_MS);
  } catch {
    // Offline or too slow: the local base is merged as it stands, and
    // `fetched: false` is how the phone says "as of the last fetch".
    return { ref: base, fetched: false };
  }
  try {
    await git(worktreePath, ["merge-base", "--is-ancestor", base, upstream]);
  } catch {
    // Diverged, or something did not resolve: the local base stands.
    return { ref: base, fetched: true };
  }
  try {
    await git(worktreePath, ["branch", "-f", base, upstream]);
    return { ref: base, fetched: true };
  } catch {
    // The base is checked out somewhere, so it cannot be moved; merge the
    // fresh remote-tracking ref instead, which `from` reports.
    return { ref: upstream, fetched: true };
  }
}

async function mergeInProgress(worktreePath: string): Promise<boolean> {
  try {
    await git(worktreePath, ["rev-parse", "--verify", "--quiet", "MERGE_HEAD"]);
    return true;
  } catch {
    // No MERGE_HEAD is exactly what "no merge in progress" looks like.
    return false;
  }
}

async function conflictedFiles(worktreePath: string): Promise<string[]> {
  try {
    const { stdout } = await git(worktreePath, ["diff", "--name-only", "--diff-filter=U", "-z"]);
    return stdout.split("\0").filter((entry) => entry.length > 0);
  } catch {
    // Only used to name files in a message that already says the merge
    // failed; unnamed is worse than nothing, never wrong.
    return [];
  }
}

async function headSha(worktreePath: string): Promise<string> {
  try {
    return (await git(worktreePath, ["rev-parse", "HEAD"])).stdout.trim();
  } catch {
    // The merge already succeeded; an empty sha only costs the phone the
    // commit link it would have opened.
    return "";
  }
}

function firstLine(text: string): string {
  return (
    text
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line && !/^(To |remote: *$|!\s)/.test(line))[0] ?? text.trim()
  );
}
