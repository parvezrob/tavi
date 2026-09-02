import path from "node:path";
import { runGh } from "./gh.js";
import { describeGitError, git } from "./git-exec.js";
import { isWithinRoots } from "./projects.js";
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
  // Inside the configured roots. git lists a worktree wherever it lives,
  // but the host's write routes (status, commit, remove…) answer only
  // inside the roots; a client can say so instead of showing a dead
  // button (#83).
  withinRoots: boolean;
}

export interface PullRequestRef {
  number: number;
  url: string;
}

// How a pull request is looked up for a branch; injectable so tests need
// no `gh`. The default shells out to `gh pr list`. The signal fires when
// the pass's budget runs out: a lookup that can stop should.
export type PullRequestLookup = (repository: string, branch: string, signal?: AbortSignal) => Promise<PullRequestRef | null>;

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

const MAX_BRANCHES = 200;

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
      const commonDir = (await git(workspace.path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])).stdout.trim();
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
      continue;
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

export async function listReposCached(roots: string[], options: ListReposOptions = {}, fresh = false): Promise<ReposAnswer> {
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
      }
      else if (line === "bare") bare = true;
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
async function attachAheadBehind(repository: string, worktrees: WorktreeInfo[], defaultBranch: string | null): Promise<void> {
  if (!defaultBranch) return;
  const target = (await refExists(repository, `refs/heads/${defaultBranch}`))
    ? `refs/heads/${defaultBranch}`
    : (await refExists(repository, `refs/remotes/origin/${defaultBranch}`))
      ? `refs/remotes/origin/${defaultBranch}`
      : null;
  if (!target) return;
  const branches = [...new Set(worktrees.flatMap((worktree) => (worktree.branch && worktree.branch !== defaultBranch ? [worktree.branch] : [])))];
  const counts = new Map<string, [number, number]>();
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
        const [ahead = 0, behind = 0] = (pair ?? "").trim().split(/\s+/).map((value) => Number.parseInt(value, 10) || 0);
        counts.set(ref.slice("refs/heads/".length), [ahead, behind]);
      }
    } catch {
      for (const branch of branches) counts.set(branch, await aheadBehind(repository, `refs/heads/${branch}`, target));
    }
  }
  for (const worktree of worktrees) {
    if (worktree.branch) {
      // Exact names only: `for-each-ref refs/heads/fix` also lists
      // `refs/heads/fix/foo`, and the map holds both under their own name.
      const pair = counts.get(worktree.branch);
      if (pair) [worktree.ahead, worktree.behind] = pair;
    } else if (worktree.head) {
      [worktree.ahead, worktree.behind] = await aheadBehind(repository, worktree.head, target);
    }
  }
}

// Pull requests for one repository's worktrees, a few at a time and within
// one budget: the badge is a nicety, so whatever has not answered when the
// budget runs out is null this poll, and the lookups still running are
// told to stop (their `gh` is killed) rather than left to finish for
// nobody (#85). The default branch is skipped (it has no PR of its own by
// construction); a lookup that throws costs the badge, never the repo.
const PR_PASS_BUDGET_MS = 3_000;
const PR_PASS_CONCURRENCY = 4;

async function attachPullRequests(
  repository: string,
  worktrees: WorktreeInfo[],
  defaultBranch: string | null,
  lookup: PullRequestLookup,
): Promise<void> {
  const candidates = worktrees.filter((worktree) => worktree.branch && worktree.branch !== defaultBranch);
  if (candidates.length === 0) return;
  const controller = new AbortController();
  const expired = new Promise<null>((resolve) => controller.signal.addEventListener("abort", () => resolve(null), { once: true }));
  const timer = setTimeout(() => controller.abort(), PR_PASS_BUDGET_MS);
  timer.unref();
  let next = 0;
  const worker = async (): Promise<void> => {
    while (next < candidates.length && !controller.signal.aborted) {
      const worktree = candidates[next] as WorktreeInfo;
      next += 1;
      try {
        // Raced as well as signalled: an injected lookup that ignores the
        // signal must not hold the whole answer past the budget.
        const value = await Promise.race([lookup(repository, worktree.branch as string, controller.signal), expired]);
        worktree.pullRequest = controller.signal.aborted ? null : value;
      } catch {
        worktree.pullRequest = null;
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(PR_PASS_CONCURRENCY, candidates.length) }, worker));
  clearTimeout(timer);
}

// `gh pr list` under the person's own login. Remembered per repo+branch —
// a minute for an answer, ten seconds for a failure (a timeout or a moment
// offline must not blank a real badge for a minute) — least recently used
// first out, and single-flight, so a phone polling every 30 s while gh is
// slow never stacks calls for the same branch. Only a PR whose head is
// *this* repository counts: `--head` alone matches any fork's branch of
// the same name, and a stranger's PR on the card would be worse than none
// (found in review, 2026-09-02). Any failure — gh missing, logged out,
// offline, not a GitHub remote, stopped by the pass's budget — is null,
// never an error.
const PR_CACHE_MS = 60_000;
const PR_FAILURE_CACHE_MS = 10_000;
const PR_CACHE_MAX_ENTRIES = 2_000;
const GH_TIMEOUT_MS = 5_000;
type PullRequestCacheEntry = { at: number; ttl: number; value: Promise<PullRequestRef | null> };
const pullRequestCache = new Map<string, PullRequestCacheEntry>();

export function cachedPullRequestLookup(repository: string, branch: string, signal?: AbortSignal): Promise<PullRequestRef | null> {
  const key = `${repository}\0${branch}`;
  const now = monotonicNow();
  const hit = pullRequestCache.get(key);
  if (hit && now - hit.at < hit.ttl) {
    // Touched: a Map keeps insertion order, so re-inserting makes it the
    // newest and the first key the least recently used.
    pullRequestCache.delete(key);
    pullRequestCache.set(key, hit);
    return hit.value;
  }
  const entry: PullRequestCacheEntry = { at: now, ttl: PR_CACHE_MS, value: Promise.resolve(null) };
  entry.value = ghPullRequest(repository, branch, signal).then((result) => {
    if (result.failed) entry.ttl = PR_FAILURE_CACHE_MS;
    return result.value;
  });
  pullRequestCache.delete(key);
  if (pullRequestCache.size >= PR_CACHE_MAX_ENTRIES) {
    const oldest = pullRequestCache.keys().next().value;
    if (oldest !== undefined) pullRequestCache.delete(oldest);
  }
  pullRequestCache.set(key, entry);
  return entry.value;
}

// The host's own writes (#79 create/link) make the cached answer stale
// at once; the next card poll asks gh again.
export function forgetPullRequest(repository: string, branch: string): void {
  pullRequestCache.delete(`${repository}\0${branch}`);
}

function monotonicNow(): number {
  return Number(process.hrtime.bigint() / 1_000_000n);
}

async function ghPullRequest(repository: string, branch: string, signal?: AbortSignal): Promise<{ value: PullRequestRef | null; failed: boolean }> {
  try {
    const { stdout } = await runGh(
      repository,
      ["pr", "list", "--head", branch, "--state", "open", "--json", "number,url,isCrossRepository", "--limit", "5"],
      { timeoutMs: GH_TIMEOUT_MS, ...(signal ? { signal } : {}) },
    );
    const parsed: unknown = JSON.parse(stdout);
    if (!Array.isArray(parsed)) return { value: null, failed: true };
    for (const item of parsed as { number?: unknown; url?: unknown; isCrossRepository?: unknown }[]) {
      if (item.isCrossRepository === false && typeof item.number === "number" && typeof item.url === "string") {
        return { value: { number: item.number, url: item.url }, failed: false };
      }
    }
    return { value: null, failed: false };
  } catch {
    return { value: null, failed: true };
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

// Local branches, default branch first, alphabetical after; capped so a
// repository with thousands of stale branches does not turn one poll into
// a megabyte, and said so when cut. Empty when git cannot list (a repo
// with no commits yet).
async function listBranches(repository: string, defaultBranch: string | null): Promise<{ names: string[]; truncated: boolean }> {
  try {
    const { stdout } = await git(repository, ["for-each-ref", "--format=%(refname:short)", "--sort=refname", "refs/heads/"]);
    const names = stdout.split("\n").filter((name) => name.length > 0);
    const others = names.filter((name) => name !== defaultBranch);
    const rest = others.slice(0, MAX_BRANCHES);
    const withDefault = defaultBranch && names.includes(defaultBranch) ? [defaultBranch, ...rest] : rest;
    return { names: withDefault, truncated: others.length > rest.length };
  } catch {
    return { names: [], truncated: false };
  }
}

export async function refExists(repository: string, ref: string): Promise<boolean> {
  try {
    await git(repository, ["rev-parse", "--verify", "--quiet", ref]);
    return true;
  } catch {
    return false;
  }
}

// Commits `left` has that `right` does not, and the reverse — the one
// ahead/behind helper (#83; source-control.ts and pull-requests.ts share
// it). 0/0 when either side is missing or they are the same ref, and when
// a side does not resolve (a remote-only default with no local copy).
export async function aheadBehind(repository: string, left: string | null, right: string | null): Promise<[number, number]> {
  if (!left || !right || left === right) return [0, 0];
  try {
    const { stdout } = await git(repository, ["rev-list", "--left-right", "--count", `${left}...${right}`]);
    const [ahead, behind] = stdout.trim().split(/\s+/).map((value) => Number.parseInt(value, 10) || 0);
    return [ahead ?? 0, behind ?? 0];
  } catch {
    return [0, 0];
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
