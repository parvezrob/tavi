import { execFile } from "node:child_process";
import path from "node:path";
import { promisify } from "node:util";
import { describeGitError, git } from "./git-exec.js";
import { scanWorkspaces } from "./workspaces.js";

const execFileAsync = promisify(execFile);

// Read-only worktree and branch visibility (#59a): "where is my work
// happening", one repository at a time. Every call here is a fixed,
// non-mutating git invocation — `worktree list`, `status`, `rev-list` — the
// same discipline as changes.ts. Nothing here creates or removes a worktree.

const MAX_REPOS = 40;
const MAX_WORKTREES_PER_REPO = 40;

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
  // worktree already is the default branch.
  ahead: number;
  behind: number;
  locked: boolean;
  prunable: boolean;
  // The open pull request for this branch, per the person's own `gh`
  // login (#74). null when there is none, when `gh` is missing or logged
  // out, or for a detached worktree — the row simply shows no badge.
  pullRequest: PullRequestRef | null;
}

export interface PullRequestRef {
  number: number;
  url: string;
}

// How a pull request is looked up for a branch; injectable so tests need
// no `gh`. The default shells out to `gh pr list`.
export type PullRequestLookup = (repository: string, branch: string) => Promise<PullRequestRef | null>;

export interface ListReposOptions {
  pullRequests?: PullRequestLookup;
}

export interface RepoInfo {
  // The main worktree's path — what a person means by "the repo".
  root: string;
  name: string;
  defaultBranch: string | null;
  worktrees: WorktreeInfo[];
}

// Repositories reachable from the configured roots, each with every
// worktree git knows about (which may live outside the roots — git found
// them, so hiding them would be a lie, not a guardrail; the guardrail is on
// *creating* new ones, in #59b). Roots that hold several repos, or a repo
// found through more than one root, each appear once.
export async function listRepos(roots: string[], options: ListReposOptions = {}): Promise<RepoInfo[]> {
  const workspaces = await scanWorkspaces(roots);
  const seen = new Set<string>();
  const repos: RepoInfo[] = [];
  const pullRequests = options.pullRequests ?? cachedPullRequestLookup;

  for (const workspace of workspaces) {
    if (repos.length >= MAX_REPOS) break;
    if (!workspace.git) continue;
    try {
      const commonDir = (await git(workspace.path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])).stdout.trim();
      if (!commonDir || seen.has(commonDir)) continue;
      seen.add(commonDir);

      const worktrees = await listWorktrees(workspace.path);
      const main = worktrees.find((worktree) => worktree.isMain) ?? worktrees[0];
      if (!main) continue;
      const defaultBranch = await findDefaultBranch(main.path);
      for (const worktree of worktrees) {
        const [ahead, behind] = await aheadBehind(main.path, worktree.branch, defaultBranch);
        worktree.ahead = ahead;
        worktree.behind = behind;
        if (worktree.branch) worktree.pullRequest = await pullRequests(main.path, worktree.branch);
      }
      repos.push({ root: main.path, name: path.basename(main.path), defaultBranch, worktrees });
    } catch {
      // One repository that this call cannot read (a stalled network mount,
      // a mid-operation .git) does not blank the whole list; its neighbours
      // still answer.
      continue;
    }
  }

  return repos;
}

async function listWorktrees(repository: string): Promise<WorktreeInfo[]> {
  let stdout: string;
  try {
    stdout = (await git(repository, ["worktree", "list", "--porcelain"])).stdout;
  } catch (error) {
    throw new Error(`git worktree list failed: ${describeGitError(error)}`);
  }
  const worktrees = parseWorktreeList(stdout).slice(0, MAX_WORKTREES_PER_REPO);
  for (const worktree of worktrees) {
    worktree.dirty = await dirtyCount(worktree.path);
  }
  return worktrees;
}

// `git worktree list --porcelain`: blank-line-separated records, the main
// worktree always first. Each record is `worktree <path>` then `HEAD <sha>`
// then one of `branch <ref>` / `detached` / `bare`, plus optional `locked
// [reason]` and `prunable [reason]`.
export function parseWorktreeList(raw: string): WorktreeInfo[] {
  const worktrees: WorktreeInfo[] = [];
  let first = true;
  for (const record of raw.split(/\n{2,}/)) {
    const lines = record.split("\n").filter((line) => line.length > 0);
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
    if (!worktreePath || bare) continue;
    worktrees.push({
      path: worktreePath,
      branch,
      head,
      isMain: first,
      dirty: 0,
      ahead: 0,
      behind: 0,
      locked,
      prunable,
      pullRequest: null,
    });
    first = false;
  }
  return worktrees;
}

// `gh pr list --head <branch>` under the person's own login, one call per
// branch, remembered for a minute per repo+branch so a phone polling every
// 30 s does not fan out into a GitHub call per worktree per poll. Any
// failure — `gh` missing, logged out, offline, not a GitHub remote — is
// null, never an error: the badge is a nicety, the list is not.
const PR_CACHE_MS = 60_000;
const GH_TIMEOUT_MS = 5_000;
const pullRequestCache = new Map<string, { at: number; value: PullRequestRef | null }>();

export async function cachedPullRequestLookup(repository: string, branch: string): Promise<PullRequestRef | null> {
  const key = `${repository}\0${branch}`;
  const hit = pullRequestCache.get(key);
  const now = Date.now();
  if (hit && now - hit.at < PR_CACHE_MS) return hit.value;
  const value = await ghPullRequest(repository, branch);
  pullRequestCache.set(key, { at: now, value });
  return value;
}

async function ghPullRequest(repository: string, branch: string): Promise<PullRequestRef | null> {
  try {
    const { stdout } = await execFileAsync(
      "gh",
      ["pr", "list", "--head", branch, "--state", "open", "--json", "number,url", "--limit", "1"],
      { cwd: repository, timeout: GH_TIMEOUT_MS, encoding: "utf8", env: { ...process.env, GH_PROMPT_DISABLED: "1", GH_NO_UPDATE_NOTIFIER: "1" } },
    );
    const parsed: unknown = JSON.parse(stdout);
    if (!Array.isArray(parsed) || parsed.length === 0) return null;
    const first = parsed[0] as { number?: unknown; url?: unknown };
    if (typeof first.number !== "number" || typeof first.url !== "string") return null;
    return { number: first.number, url: first.url };
  } catch {
    return null;
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
async function findDefaultBranch(mainWorktreePath: string): Promise<string | null> {
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

async function refExists(repository: string, ref: string): Promise<boolean> {
  try {
    await git(repository, ["rev-parse", "--verify", "--quiet", ref]);
    return true;
  } catch {
    return false;
  }
}

async function aheadBehind(repository: string, branch: string | null, defaultBranch: string | null): Promise<[number, number]> {
  if (!branch || !defaultBranch || branch === defaultBranch) return [0, 0];
  try {
    const { stdout } = await git(repository, ["rev-list", "--left-right", "--count", `${branch}...${defaultBranch}`]);
    const [ahead, behind] = stdout.trim().split(/\s+/).map((value) => Number.parseInt(value, 10) || 0);
    return [ahead ?? 0, behind ?? 0];
  } catch {
    // The default branch may not exist as a ref reachable from here (e.g.
    // a remote-only default with no local copy yet).
    return [0, 0];
  }
}
