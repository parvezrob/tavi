import path from "node:path";
import { describeGitError, git } from "./git-exec.js";
import { type AheadBehind, aheadBehind, countedPair, findDefaultBranch, listBranches, refExists } from "./git-refs.js";
import { monotonicNow } from "./monotonic.js";
import { isWithinRoots } from "./projects.js";
import {
  attachPullRequests,
  cachedPullRequestLookup,
  type PullRequestLookup,
  type PullRequestRef,
} from "./pull-request-cache.js";
import { scanWorkspaces } from "./workspaces.js";

// Read-only worktree and branch visibility (#59a): "where is my work
// happening", one repository at a time. Every call here is a fixed,
// non-mutating git invocation — `worktree list`, `status`, `for-each-ref` —
// the same discipline as changes.ts. Nothing here creates or removes a
// worktree.

const MAX_REPOS = 40;
const MAX_WORKTREES_PER_REPO = 40;
// `status` per worktree, this many at a time: a repository with forty
// worktrees must not fork forty git processes at once (#83).
const STATUS_CONCURRENCY = 4;

export interface WorktreeInfo {
  path: string;
  // null for a detached HEAD.
  branch: string | null;
  head: string;
  // The repository's original checkout — first in `git worktree list`.
  isMain: boolean;
  // Files git status reports as changed or untracked; not a diff, a count.
  dirty: number;
  // Commits this branch has that the default branch does not, and vice
  // versa. 0/0 when there is no default branch to compare against, or the
  // worktree already is the default branch. A detached worktree is
  // compared by its HEAD.
  ahead: number;
  behind: number;
  locked: boolean;
  prunable: boolean;
  // The open pull request for this branch, per the person's own `gh`
  // login (#74). null when there is none, when `gh` is missing or logged
  // out, or for a detached worktree — the row simply shows no badge.
  pullRequest: PullRequestRef | null;
  // Why ahead/behind could not be measured, as a sentence (#98). Absent
  // when they were: a git failure must not render as "in sync".
  aheadBehindFailed?: string;
  // Inside the configured roots. git lists a worktree wherever it lives,
  // but the host's write routes (status, commit, remove…) answer only
  // inside the roots; a client can say so instead of showing a dead
  // button (#83).
  withinRoots: boolean;
}

export interface ListReposOptions {
  pullRequests?: PullRequestLookup;
}

export interface RepoInfo {
  // The main worktree's path — what a person means by "the repo".
  root: string;
  name: string;
  defaultBranch: string | null;
  // Local branch names, for "start from" when creating a worktree (#75).
  // Capped; the default branch is always first when present.
  branches: string[];
  worktrees: WorktreeInfo[];
  // The worktree or branch list was cut at its cap; what is shown is
  // real, what is missing is unnamed (#83).
  truncated: boolean;
}

export interface ReposAnswer {
  repos: RepoInfo[];
  // More repositories than the cap: the list stops, it does not lie.
  truncated: boolean;
  // Why nothing could be listed at all — git is not installed — as a
  // sentence; null when the listing ran. An empty list with no error
  // means there are no repositories (#83).
  error: string | null;
}

// Repositories reachable from the configured roots, each with every
// worktree git knows about (which may live outside the roots — git found
// them, so hiding them would be a lie, not a guardrail; the guardrail is on
// *creating* new ones, in #59b). Roots that hold several repos, or a repo
// found through more than one root, each appear once.
export async function listRepos(roots: string[], options: ListReposOptions = {}): Promise<ReposAnswer> {
  const workspaces = await scanWorkspaces(roots);
  const seen = new Set<string>();
  const repos: RepoInfo[] = [];
  const pullRequests = options.pullRequests ?? cachedPullRequestLookup;
  let truncated = false;
  let error: string | null = null;

  for (const workspace of workspaces) {
    if (!workspace.git) continue;
    if (repos.length >= MAX_REPOS) {
      truncated = true;
      break;
    }
    try {
      const commonDir = (
        await git(workspace.path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
      ).stdout.trim();
      if (!commonDir || seen.has(commonDir)) continue;
      seen.add(commonDir);

      const listed = await listWorktrees(workspace.path);
      const worktrees = listed.worktrees;
      const main = worktrees.find((worktree) => worktree.isMain) ?? worktrees[0];
      if (!main) continue;
      for (const worktree of worktrees) worktree.withinRoots = isWithinRoots(worktree.path, roots);
      const defaultBranch = await findDefaultBranch(main.path);
      await attachAheadBehind(main.path, worktrees, defaultBranch);
      await attachPullRequests(main.path, worktrees, defaultBranch, pullRequests);
      const branches = await listBranches(main.path, defaultBranch);
      repos.push({
        root: main.path,
        name: path.basename(main.path),
        defaultBranch,
        branches: branches.names,
        worktrees,
        truncated: listed.truncated || branches.truncated,
      });
    } catch (caught) {
      // No git at all is one sentence for the whole answer, not an empty
      // list that reads as "no repositories" (#72).
      if (isGitMissing(caught)) {
        error = "git is not installed on this computer.";
        break;
      }
      // One repository that this call cannot read (a stalled network mount,
      // a mid-operation .git) does not blank the whole list; its neighbours
      // still answer.
    }
  }

  return { repos, truncated, error };
}

function isGitMissing(error: unknown): boolean {
  const code = (error as { code?: unknown }).code;
  const message = error instanceof Error ? error.message : String(error);
  return code === "ENOENT" && /\bgit\b/.test(message);
}

// `/api/repos` from the cache (#83, owner-felt 2026-09-02: a 3 s answer
// every 30 s while the phone polled). The last answer is served at once
// and refreshed in the background once it is older than REPOS_REFRESH_MS;
// only an answer older than REPOS_FRESH_MS — or a caller asking for
// `fresh` — waits for git. One computation at a time, and every write the
// host makes to a repository calls `invalidateRepos()` so the next poll
// sees it.
const REPOS_FRESH_MS = 90_000;
const REPOS_REFRESH_MS = 15_000;
let reposCache: { key: string; at: number; value: ReposAnswer } | null = null;
let reposInFlight: Promise<ReposAnswer> | null = null;

export function invalidateRepos(): void {
  reposCache = null;
}

export async function listReposCached(
  roots: string[],
  options: ListReposOptions = {},
  fresh = false,
): Promise<ReposAnswer> {
  const key = roots.join("\0");
  const now = monotonicNow();
  const refresh = (): Promise<ReposAnswer> => {
    if (!reposInFlight) {
      reposInFlight = listRepos(roots, options)
        .then((value) => {
          reposCache = { key, at: monotonicNow(), value };
          return value;
        })
        .finally(() => {
          reposInFlight = null;
        });
    }
    return reposInFlight;
  };
  if (!fresh && reposCache && reposCache.key === key && now - reposCache.at < REPOS_FRESH_MS) {
    if (now - reposCache.at > REPOS_REFRESH_MS) void refresh().catch(() => undefined);
    return reposCache.value;
  }
  return refresh();
}

async function listWorktrees(repository: string): Promise<{ worktrees: WorktreeInfo[]; truncated: boolean }> {
  let stdout: string;
  try {
    stdout = (await git(repository, ["worktree", "list", "--porcelain", "-z"])).stdout;
  } catch (error) {
    if (isGitMissing(error)) throw error;
    throw new Error(`git worktree list failed: ${describeGitError(error)}`);
  }
  const all = parseWorktreeList(stdout);
  const worktrees = all.slice(0, MAX_WORKTREES_PER_REPO);
  const counts = await mapPool(worktrees, STATUS_CONCURRENCY, (worktree) => dirtyCount(worktree.path));
  worktrees.forEach((worktree, index) => {
    worktree.dirty = counts[index] ?? 0;
  });
  return { worktrees, truncated: all.length > worktrees.length };
}

// `git worktree list --porcelain -z`: NUL-terminated lines, records ended
// by an extra NUL, the main worktree always first. (The newline form is
// read too, for callers and tests that still hand it over; with -z a path
// holding a newline comes through whole — #72.) Each record is `worktree
// <path>` then `HEAD <sha>` then one of `branch <ref>` / `detached` /
// `bare`, plus optional `locked [reason]` and `prunable [reason]`.
export function parseWorktreeList(raw: string): WorktreeInfo[] {
  const worktrees: WorktreeInfo[] = [];
  const nulTerminated = raw.includes("\0");
  const records = nulTerminated ? raw.split("\0\0") : raw.split(/\n{2,}/);
  const lineBreak = nulTerminated ? "\0" : "\n";
  let first = true;
  for (const record of records) {
    const lines = record.split(lineBreak).filter((line) => line.length > 0);
    if (lines.length === 0) continue;
    let worktreePath: string | undefined;
    let head = "";
    let branch: string | null = null;
    let bare = false;
    let locked = false;
    let prunable = false;
    for (const line of lines) {
      if (line.startsWith("worktree ")) worktreePath = line.slice("worktree ".length);
      else if (line.startsWith("HEAD ")) head = line.slice("HEAD ".length);
      else if (line.startsWith("branch ")) {
        const ref = line.slice("branch ".length);
        branch = ref.startsWith("refs/heads/") ? ref.slice("refs/heads/".length) : ref;
      } else if (line === "bare") bare = true;
      else if (line.startsWith("locked")) locked = true;
      else if (line.startsWith("prunable")) prunable = true;
    }
    if (!worktreePath) continue;
    // A bare repository's first record is the repository itself, not a
    // checkout: skipped, and the next record is not the main worktree.
    const isMain = first;
    first = false;
    if (bare) continue;
    worktrees.push({
      path: worktreePath,
      branch,
      head,
      isMain,
      dirty: 0,
      ahead: 0,
      behind: 0,
      locked,
      prunable,
      pullRequest: null,
      withinRoots: true,
    });
  }
  return worktrees;
}

// Ahead/behind for every worktree in one git call: `for-each-ref
// --format=%(ahead-behind:<default>)` over the branches the worktrees are
// on (git ≥ 2.41; older git falls back to one `rev-list` per branch). The
// default is named as a full ref — a tag called `main` must not win — and
// when there is no local copy, its remote-tracking ref stands in. A
// detached worktree is compared by its HEAD (#72).
async function attachAheadBehind(
  repository: string,
  worktrees: WorktreeInfo[],
  defaultBranch: string | null,
): Promise<void> {
  if (!defaultBranch) return;
  const target = (await refExists(repository, `refs/heads/${defaultBranch}`))
    ? `refs/heads/${defaultBranch}`
    : (await refExists(repository, `refs/remotes/origin/${defaultBranch}`))
      ? `refs/remotes/origin/${defaultBranch}`
      : null;
  if (!target) {
    // A named default branch git has no ref for (a stale origin/HEAD, or a
    // clone with neither the local branch nor its remote-tracking copy):
    // nothing can be compared, so every row says so instead of zeros (#98).
    const unresolved = `git could not find a ref for ${defaultBranch} to compare against.`;
    for (const worktree of worktrees) if (worktree.branch !== defaultBranch) worktree.aheadBehindFailed = unresolved;
    return;
  }
  const branches = [
    ...new Set(
      worktrees.flatMap((worktree) => (worktree.branch && worktree.branch !== defaultBranch ? [worktree.branch] : [])),
    ),
  ];
  const counts = new Map<string, AheadBehind>();
  if (branches.length > 0) {
    try {
      const { stdout } = await git(repository, [
        "for-each-ref",
        `--format=%(refname)%00%(ahead-behind:${target})`,
        ...branches.map((branch) => `refs/heads/${branch}`),
      ]);
      for (const line of stdout.split("\n")) {
        const [ref, pair] = line.split("\0");
        if (!ref?.startsWith("refs/heads/")) continue;
        const counted = countedPair(pair ?? "");
        // A field this git left empty (it does that for an unresolvable
        // target) is not a measurement; only two integers are (#98 review).
        if (counted) counts.set(ref.slice("refs/heads/".length), counted);
      }
    } catch {
      // Older git has no `%(ahead-behind:…)`; ask per branch instead. A
      // branch that fails there carries its own reason to the row.
      for (const branch of branches) counts.set(branch, await aheadBehind(repository, `refs/heads/${branch}`, target));
    }
  }
  for (const worktree of worktrees) {
    // A worktree standing on the default branch is 0/0 by construction, and
    // one with neither a branch nor a HEAD has nothing to compare.
    if (worktree.branch === defaultBranch || (!worktree.branch && !worktree.head)) continue;
    // Exact names only: `for-each-ref refs/heads/fix` also lists
    // `refs/heads/fix/foo`, and the map holds both under their own name. A
    // branch missing from it, or listed without two counts, was not measured
    // and says so rather than staying at 0/0 (#98).
    const measured = worktree.branch
      ? counts.get(worktree.branch)
      : await aheadBehind(repository, worktree.head, target);
    if (measured?.ok) {
      worktree.ahead = measured.ahead;
      worktree.behind = measured.behind;
    } else {
      worktree.aheadBehindFailed =
        measured?.error ?? `git did not report how ${worktree.branch} compares with ${target}.`;
    }
  }
}

// Changed or untracked entries per `status --porcelain=v2`, one worktree at
// a time — the count a row needs ("2 dirty"), not the files themselves. A
// renamed-or-copied entry (`2 ...`) carries its origin path as a second
// NUL-terminated field; that field must be consumed, not counted as a
// second changed file (the same shape `changes.ts`'s v1 parser handles by
// advancing past a rename's `from` field).
async function dirtyCount(worktreePath: string): Promise<number> {
  try {
    const { stdout } = await git(worktreePath, ["status", "--porcelain=v2", "-z", "--untracked-files=all"]);
    const parts = stdout.split("\0").filter((entry) => entry.length > 0);
    let count = 0;
    for (let index = 0; index < parts.length; index += 1) {
      count += 1;
      if (parts[index]?.startsWith("2 ")) index += 1;
    }
    return count;
  } catch {
    // A worktree git listed but that is missing on disk (moved, deleted
    // outside git): nothing to report, not a failure of the whole repo.
    return 0;
  }
}

// `map` with at most `limit` calls in flight, results in input order.
async function mapPool<T, R>(items: readonly T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  const worker = async (): Promise<void> => {
    while (next < items.length) {
      const index = next;
      next += 1;
      results[index] = await fn(items[index] as T);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}
