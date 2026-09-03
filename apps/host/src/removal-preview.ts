import { promises as fs } from "node:fs";
import { listChanges } from "./changes.js";
import { describeGitError, git } from "./git-exec.js";
import { parseWorktreeList } from "./git.js";
import { baseBranch, currentBranch, upstreamInfo } from "./git-refs.js";
import { isWithinRoots } from "./projects.js";
import type { HerdrAgentInfo } from "./types.js";

// Removal, step one (#81, #73 part 6). Removing is the one destructive
// thing this host does to a repository, so it is two steps: this preview,
// which names what would be lost, and `removal.ts`, which must repeat those
// counts back before it touches anything. Every count here is measured or
// the preview is refused — a git read that failed must never read as
// "nothing would be lost".

export interface RemovalAgent {
  paneId: string;
  tabId: string;
  kind: string;
  status: string;
  // Where the agent works — named for the ones removal takes down
  // *outside* the worktree (`alsoClosed`), so the preview can say which.
  cwd?: string;
}

export interface RemovalPreview {
  path: string;
  branch: string | null;
  isMain: boolean;
  // `git worktree lock`: the person's own "do not remove".
  locked: boolean;
  repoRoot: string;
  base: string | null;
  uncommitted: { files: number; additions: number; deletions: number };
  unpushed: { commits: number; upstream: string | null; remote: string | null };
  agents: RemovalAgent[];
  // Agents *outside* the worktree that go with it anyway: herdr closes
  // whole tabs, so a tab holding an agent inside the worktree and one
  // elsewhere loses both (#83). The preview says so before anyone taps.
  alsoClosed: RemovalAgent[];
  // The branch's commits are all reachable from its base.
  branchMerged: boolean;
}

export interface RemovalDeps {
  // The agents herdr knows about; only those inside the worktree count.
  agents?: () => Promise<HerdrAgentInfo[]>;
  closeTab?: (tabId: string) => Promise<boolean>;
}

export type RemovalPreviewResult =
  | { ok: true; preview: RemovalPreview }
  | { ok: false; status: 400 | 404 | 503; error: string };

export async function previewRemoval(worktreePath: string, deps: RemovalDeps = {}): Promise<RemovalPreviewResult> {
  const located = await locateWorktree(worktreePath);
  if (!located.ok) return located;
  const { main, isMain, locked } = located;
  let branch: string | null;
  try {
    branch = await currentBranch(worktreePath);
  } catch (error) {
    return { ok: false, status: 503, error: `git could not read that worktree: ${describeGitError(error)}` };
  }
  // Every count here is measured or the preview is refused: a git read
  // that fails must never read as "nothing would be lost" (#81 review).
  const changes = await listChanges(worktreePath);
  if (!changes.ok)
    return {
      ok: false,
      status: 503,
      error: `Could not count the uncommitted changes, so nothing was removed: ${changes.error}`,
    };
  const uncommitted = {
    files: changes.files.length,
    additions: changes.files.reduce((sum, file) => sum + (file.additions ?? 0), 0),
    deletions: changes.files.reduce((sum, file) => sum + (file.deletions ?? 0), 0),
  };
  const base = await baseBranch(worktreePath, branch);
  const upstream = branch ? await upstreamInfo(worktreePath, branch) : null;
  let commits: number;
  try {
    if (!branch) {
      // Detached: whatever HEAD has that no branch, tag, or remote holds
      // would be orphaned with the worktree.
      commits = await countCommits(worktreePath, ["HEAD", "--not", "--branches", "--remotes", "--tags"]);
    } else if (upstream) {
      commits = upstream.ahead;
    } else if (base && base !== branch) {
      commits = await countCommits(worktreePath, [`${base}..${branch}`]);
    } else {
      commits = 0;
    }
  } catch (error) {
    return {
      ok: false,
      status: 503,
      error: `Could not count the unpushed commits, so nothing was removed: ${describeGitError(error)}`,
    };
  }
  let remote: string | null = null;
  try {
    remote =
      (await git(worktreePath, ["remote"])).stdout
        .split("\n")
        .map((line) => line.trim())
        .filter(Boolean)[0] ?? null;
  } catch {
    // Only used to name where a push would go in the preview's sentence;
    // the counts that decide anything are measured or the preview fails.
    remote = null;
  }
  const branchMerged = branch && base && branch !== base ? await isAncestor(worktreePath, branch, base) : false;
  const { inside: agents, alsoClosed } = await agentsInside(worktreePath, deps);
  return {
    ok: true,
    preview: {
      path: worktreePath,
      branch,
      isMain,
      locked,
      repoRoot: main,
      base,
      uncommitted,
      unpushed: { commits, upstream: upstream?.name ?? null, remote },
      agents,
      alsoClosed,
      branchMerged,
    },
  };
}

async function countCommits(cwd: string, revisions: string[]): Promise<number> {
  const { stdout } = await git(cwd, ["rev-list", "--count", ...revisions]);
  return Number.parseInt(stdout.trim(), 10) || 0;
}

type Located =
  | { ok: true; main: string; isMain: boolean; locked: boolean }
  | { ok: false; status: 404 | 503; error: string };

async function locateWorktree(worktreePath: string): Promise<Located> {
  let listed: ReturnType<typeof parseWorktreeList>;
  try {
    listed = parseWorktreeList((await git(worktreePath, ["worktree", "list", "--porcelain", "-z"])).stdout);
  } catch (error) {
    if (/not a git repository/i.test(describeGitError(error)))
      return { ok: false, status: 404, error: "That folder is not inside a git repository." };
    return { ok: false, status: 503, error: `git could not read that worktree: ${describeGitError(error)}` };
  }
  const main = listed.find((worktree) => worktree.isMain);
  if (!main) return { ok: false, status: 404, error: "That folder is not inside a git repository." };
  let mainReal = main.path;
  let match: (typeof listed)[number] | undefined;
  for (const worktree of listed) {
    let real = worktree.path;
    try {
      real = await fs.realpath(worktree.path);
    } catch {
      // A registered worktree whose folder is gone cannot be the one the
      // phone named; skip it rather than matching on a stale path.
      continue;
    }
    if (worktree.isMain) mainReal = real;
    if (real === worktreePath) match = worktree;
  }
  if (!match)
    return {
      ok: false,
      status: 404,
      error: "That folder is not a worktree of its repository — only a whole worktree can be removed.",
    };
  return { ok: true, main: mainReal, isMain: match.isMain, locked: match.locked };
}

async function isAncestor(cwd: string, branch: string, base: string): Promise<boolean> {
  try {
    await git(cwd, ["merge-base", "--is-ancestor", branch, base]);
    return true;
  } catch {
    // `merge-base --is-ancestor` exits non-zero for "not an ancestor",
    // which is the answer; a branch is only reported merged on proof.
    return false;
  }
}

async function agentsInside(
  worktreePath: string,
  deps: RemovalDeps,
): Promise<{ inside: RemovalAgent[]; alsoClosed: RemovalAgent[] }> {
  const none = { inside: [], alsoClosed: [] };
  if (!deps.agents) return none;
  let agents: HerdrAgentInfo[];
  try {
    agents = await deps.agents();
  } catch {
    // herdr away: no agent can be inside the worktree that this host could
    // close, and removal never depends on herdr answering.
    return none;
  }
  const inside: RemovalAgent[] = [];
  const outside: RemovalAgent[] = [];
  for (const agent of agents) {
    if (!agent.cwd) continue;
    let real = agent.cwd;
    try {
      real = await fs.realpath(agent.cwd);
    } catch {
      // A cwd that no longer exists cannot be inside the worktree.
      continue;
    }
    const entry = { paneId: agent.id, tabId: agent.tabId, kind: agent.agent, status: agent.status };
    if (isWithinRoots(real, [worktreePath])) inside.push(entry);
    else outside.push({ ...entry, cwd: agent.cwd });
  }
  // herdr closes tabs, not panes: whatever else shares a tab with an
  // agent inside the worktree goes down with it.
  const tabs = new Set(inside.map((agent) => agent.tabId).filter(Boolean));
  return { inside, alsoClosed: outside.filter((agent) => tabs.has(agent.tabId)) };
}
