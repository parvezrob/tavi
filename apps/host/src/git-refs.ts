import { describeGitError, git } from "./git-exec.js";

// Facts about a repository's refs, one fixed non-mutating git read each,
// shared by every consumer that needs them (git.ts, source-control.ts,
// worktrees.ts, pull-requests.ts). Split out of git.ts in #98.

// What "off main" means for this repository: the remote's default branch
// when one is configured, else a local `main` or `master`, else nothing to
// compare against. Checked as refs, not against which branches happen to be
// checked out in a worktree right now — a repo can have a `main` nobody is
// standing on, and that is the ordinary case this feature is for.
export async function findDefaultBranch(mainWorktreePath: string): Promise<string | null> {
  try {
    const { stdout } = await git(mainWorktreePath, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]);
    const ref = stdout.trim().replace(/^origin\//, "");
    if (ref) return ref;
  } catch {
    // No remote, or no origin/HEAD set locally — fall through.
  }
  if (await refExists(mainWorktreePath, "refs/heads/main")) return "main";
  if (await refExists(mainWorktreePath, "refs/heads/master")) return "master";
  return null;
}

export async function refExists(repository: string, ref: string): Promise<boolean> {
  try {
    await git(repository, ["rev-parse", "--verify", "--quiet", ref]);
    return true;
  } catch {
    // `rev-parse --verify` exits non-zero for exactly one reason here: no
    // such ref. That is the answer, not a failure to report.
    return false;
  }
}

const MAX_BRANCHES = 200;

// Local branches, default branch first, alphabetical after; capped so a
// repository with thousands of stale branches does not turn one poll into
// a megabyte, and said so when cut. Empty when git cannot list (a repo
// with no commits yet).
export async function listBranches(
  repository: string,
  defaultBranch: string | null,
): Promise<{ names: string[]; truncated: boolean }> {
  try {
    const { stdout } = await git(repository, [
      "for-each-ref",
      "--format=%(refname:short)",
      "--sort=refname",
      "refs/heads/",
    ]);
    const names = stdout.split("\n").filter((name) => name.length > 0);
    const others = names.filter((name) => name !== defaultBranch);
    const rest = others.slice(0, MAX_BRANCHES);
    const withDefault = defaultBranch && names.includes(defaultBranch) ? [defaultBranch, ...rest] : rest;
    return { names: withDefault, truncated: others.length > rest.length };
  } catch {
    // A repository with no commits yet has no branches to list; the picker
    // falls back to typing a base, which is the same experience.
    return { names: [], truncated: false };
  }
}

// The checked-out branch, or null on a detached HEAD. Throws when the path
// is not a worktree git can read.
export async function currentBranch(worktreePath: string): Promise<string | null> {
  const { stdout } = await git(worktreePath, ["symbolic-ref", "--quiet", "--short", "HEAD"], undefined, [0, 1]);
  return stdout.trim() || null;
}

export interface UpstreamInfo {
  name: string;
  // Commits not yet pushed / not yet pulled, against the tracking ref.
  ahead: number;
  behind: number;
}

export async function upstreamInfo(worktreePath: string, branch: string): Promise<UpstreamInfo | null> {
  try {
    const name = (
      await git(worktreePath, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", `${branch}@{upstream}`])
    ).stdout.trim();
    if (!name) return null;
    const { stdout } = await git(worktreePath, ["rev-list", "--left-right", "--count", `${branch}...${name}`]);
    const [ahead = 0, behind = 0] = stdout
      .trim()
      .split(/\s+/)
      .map((value) => Number.parseInt(value, 10) || 0);
    return { name, ahead, behind };
  } catch {
    // No upstream configured, or it was deleted on the remote.
    return null;
  }
}

// `branch.<b>.pushRemote` → `remote.pushDefault` → `origin` → the only
// remote there is. null when the repository has none.
export async function pushRemote(worktreePath: string, branch: string): Promise<string | null> {
  let remotes: string[];
  try {
    remotes = (await git(worktreePath, ["remote"])).stdout
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean);
  } catch {
    // No repository to ask, so no remote to name; the caller says "no
    // remote to push to", which is what the person would find.
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

export async function baseBranch(worktreePath: string, branch: string | null): Promise<string | null> {
  if (branch) {
    try {
      const configured = (await git(worktreePath, ["config", "--get", `branch.${branch}.base`])).stdout.trim();
      if (configured && (await refExists(worktreePath, configured))) return configured;
    } catch {
      // Not configured: fall through to the repository's default.
    }
  }
  const fallback = await findDefaultBranch(worktreePath);
  return fallback;
}

/**
 * Commits `left` has that `right` does not, and the reverse — or why git
 * could not say. A failed comparison is never `0`/`0` (#98): "in sync" is
 * the most reassuring thing this host can tell a person, so it is said only
 * when git actually said it. The failure arm carries the status a route
 * would otherwise invent, as every other result type here does.
 */
export type AheadBehind = { ok: true; ahead: number; behind: number } | { ok: false; status: 503; error: string };

// The one ahead/behind helper (#83; git.ts, source-control.ts and
// pull-requests.ts share it). 0/0 when either side is missing or they are
// the same ref — nothing was compared and nothing is unknown.
export async function aheadBehind(repository: string, left: string | null, right: string | null): Promise<AheadBehind> {
  if (!left || !right || left === right) return { ok: true, ahead: 0, behind: 0 };
  try {
    const { stdout } = await git(repository, ["rev-list", "--left-right", "--count", `${left}...${right}`]);
    const counted = countedPair(stdout);
    return (
      counted ?? {
        ok: false,
        status: 503,
        error: `git compared ${left} with ${right} but did not answer with two counts.`,
      }
    );
  } catch (error) {
    // A ref that does not resolve (a remote-only default with no local
    // copy), an index lock, a timeout — the caller decides what to do, but
    // it is never told a number git did not produce.
    return { ok: false, status: 503, error: describeGitError(error) };
  }
}

// Exactly two integers, or nothing: `Number.parseInt(x) || 0` turned an
// empty field, a one-word answer, and "not-a-number" alike into a confident
// 0/0 (#98 review).
export function countedPair(text: string): { ok: true; ahead: number; behind: number } | undefined {
  const parts = text.trim().split(/\s+/);
  if (parts.length !== 2) return undefined;
  const [ahead, behind] = parts.map((value) => (/^\d+$/.test(value) ? Number.parseInt(value, 10) : Number.NaN));
  if (ahead === undefined || behind === undefined || Number.isNaN(ahead) || Number.isNaN(behind)) return undefined;
  return { ok: true, ahead, behind };
}
