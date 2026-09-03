import { runGh } from "./gh.js";
import { monotonicNow } from "./monotonic.js";

// The pull-request badge on a worktree row (#74): looked up through the
// person's own `gh` login, remembered so a phone polling every 30 s does not
// re-run `gh` for every branch, and never allowed to cost more than the
// badge is worth. Split out of git.ts in #98 — the listing and the cache in
// front of `gh` are two reasons to change.

export interface PullRequestRef {
  number: number;
  url: string;
}

// How a pull request is looked up for a branch; injectable so tests need
// no `gh`. The default shells out to `gh pr list`. The signal fires when
// the pass's budget runs out: a lookup that can stop should.
export type PullRequestLookup = (
  repository: string,
  branch: string,
  signal?: AbortSignal,
) => Promise<PullRequestRef | null>;

// Pull requests for one repository's worktrees, a few at a time and within
// one budget: the badge is a nicety, so whatever has not answered when the
// budget runs out is null this poll, and the lookups still running are
// told to stop (their `gh` is killed) rather than left to finish for
// nobody (#85). The default branch is skipped (it has no PR of its own by
// construction); a lookup that throws costs the badge, never the repo.
const PR_PASS_BUDGET_MS = 3_000;
const PR_PASS_CONCURRENCY = 4;

export async function attachPullRequests(
  repository: string,
  worktrees: { branch: string | null; pullRequest: PullRequestRef | null }[],
  defaultBranch: string | null,
  lookup: PullRequestLookup,
): Promise<void> {
  const candidates = worktrees.filter((worktree) => worktree.branch && worktree.branch !== defaultBranch);
  if (candidates.length === 0) return;
  const controller = new AbortController();
  const expired = new Promise<null>((resolve) =>
    controller.signal.addEventListener("abort", () => resolve(null), { once: true }),
  );
  const timer = setTimeout(() => controller.abort(), PR_PASS_BUDGET_MS);
  timer.unref();
  let next = 0;
  const worker = async (): Promise<void> => {
    while (next < candidates.length && !controller.signal.aborted) {
      const worktree = candidates[next] as (typeof candidates)[number];
      next += 1;
      try {
        // Raced as well as signalled: an injected lookup that ignores the
        // signal must not hold the whole answer past the budget.
        const value = await Promise.race([lookup(repository, worktree.branch as string, controller.signal), expired]);
        worktree.pullRequest = controller.signal.aborted ? null : value;
      } catch {
        // The badge is a nicety: a lookup that threw costs this row its
        // badge for one poll, never the repository's whole answer.
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

export function cachedPullRequestLookup(
  repository: string,
  branch: string,
  signal?: AbortSignal,
): Promise<PullRequestRef | null> {
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

async function ghPullRequest(
  repository: string,
  branch: string,
  signal?: AbortSignal,
): Promise<{ value: PullRequestRef | null; failed: boolean }> {
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
    // Every way this can fail is one the caller already treats as "no
    // badge"; `failed` shortens the cache so a real badge comes back fast.
    return { value: null, failed: true };
  }
}
