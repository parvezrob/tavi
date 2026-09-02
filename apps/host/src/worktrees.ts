import { promises as fs } from "node:fs";
import path from "node:path";
import { listChanges } from "./changes.js";
import { describeGitError, git } from "./git-exec.js";
import { findDefaultBranch, parseWorktreeList, refExists } from "./git.js";
import { isWithinRoots } from "./projects.js";
import { leftoverName } from "./removal-sweep.js";
import { baseBranch, currentBranch, pushBranch, upstreamInfo } from "./source-control.js";
import type { HerdrAgentInfo } from "./types.js";

// Creating a worktree from the phone (#75, #73 part 2; PRD §7.12). The one
// write to a repository this host makes so far, and it is a fixed argv
// `execFile` chain — `worktree add`, two `config --local`, a file copy —
// never a shell, never a path the phone typed used unchecked: the
// repository is realpath'd and the new folder is judged against the roots
// before git hears about it (the #24 / #57 rule).
//
// Mechanics follow what works in Orca (docs/ORCA_SOURCE_CONTROL_RESEARCH.md
// §"What to copy"): `--no-track` so status never says "behind N" before the
// branch is pushed, `push.autoSetupRemote` so the first push just works,
// `branch.<b>.base` so "vs main" survives, and the ignored setup files a
// checkout needs to run copied across.

export interface CreateWorktreeRequest {
  // A folder inside the repository, as the phone has it.
  repo: string;
  branch: string;
  // A ref to start from; the repository's default branch when absent.
  base?: string | undefined;
}

export interface CreatedWorktree {
  path: string;
  branch: string;
  base: string;
  // The repository's main worktree, so the phone can find the card.
  repoRoot: string;
  // Ignored setup files carried over from the main worktree (`.env` and
  // friends). A count, never the names: their contents are secrets by the
  // redaction rule and their names are noise.
  copiedSetupFiles: number;
}

export type CreateWorktreeResult =
  | { ok: true; worktree: CreatedWorktree }
  | { ok: false; status: 400 | 404 | 409 | 503; error: string; outsideRoots?: true };

// Top-level files a fresh checkout usually needs and git deliberately does
// not carry: copied when present in the main worktree and absent in the
// new one. Never read here, only copied.
const SETUP_FILES = [".env", ".envrc", ".tool-versions", ".nvmrc", ".node-version", ".ruby-version", ".python-version"];
const SETUP_PREFIXES = [".env."];
const MAX_BRANCH_CHARACTERS = 200;
const WORKTREE_ADD_TIMEOUT_MS = 120_000;

export async function createWorktree(
  request: CreateWorktreeRequest,
  roots: readonly string[],
  options: { allowOutsideRoots: boolean },
): Promise<CreateWorktreeResult> {
  const repo = await resolveRepository(request.repo);
  if (!repo.ok) return repo;

  const branch = request.branch.trim();
  if (!branch || branch.length > MAX_BRANCH_CHARACTERS || branch.includes("\0")) {
    return { ok: false, status: 400, error: "branch must be a branch name." };
  }
  if (!(await validBranchName(repo.main, branch))) {
    return { ok: false, status: 400, error: `"${branch}" is not a valid branch name.` };
  }
  if (await refExists(repo.main, `refs/heads/${branch}`)) {
    return { ok: false, status: 409, error: `A branch named ${branch} already exists in ${path.basename(repo.main)}.` };
  }

  let base = request.base?.trim() || null;
  if (base) {
    if (base.includes("\0") || base.startsWith("-") || !(await refExists(repo.main, base))) {
      return { ok: false, status: 400, error: `There is no branch or commit named ${base} in ${path.basename(repo.main)}.` };
    }
  } else {
    base = await findDefaultBranch(repo.main);
    if (!base) {
      return { ok: false, status: 400, error: `${path.basename(repo.main)} has no main or master branch to start from; name a base.` };
    }
  }

  const target = worktreePath(repo.main, branch);
  // Judged after realpath on both sides (the #57 trap: a symlinked root
  // or /tmp must not read as "outside" and train people to tap through).
  if (!(await withinRootsAfterRealpath(target, roots)) && !options.allowOutsideRoots) {
    return {
      ok: false,
      status: 400,
      error: `The new worktree would be created at ${target}, outside your project roots. Confirm the location to continue.`,
      outsideRoots: true,
    };
  }
  if (await exists(target)) {
    return { ok: false, status: 409, error: `${target} already exists.` };
  }

  try {
    // A checkout of a large repository, or a slow post-checkout hook, needs
    // more than the local budget; a failure rolls back what this call made.
    await git(repo.main, ["worktree", "add", "--no-track", "-b", branch, target, base], undefined, [0], WORKTREE_ADD_TIMEOUT_MS);
  } catch (error) {
    const reason = describeGitError(error);
    await rollBackCreate(repo.main, target, branch);
    const timedOut = /SIGTERM|ETIMEDOUT/i.test(error instanceof Error ? error.message : "") && !/fatal:|error:/i.test(reason);
    return { ok: false, status: 503, error: timedOut ? `git took longer than ${WORKTREE_ADD_TIMEOUT_MS / 1000} s to create the worktree, so it was rolled back. Try again on the computer.` : `git could not create the worktree: ${reason}` };
  }
  // Best effort after the worktree exists: a failed config write is not
  // worth a half-made worktree the phone was never told about.
  try {
    await git(target, ["config", "--local", "push.autoSetupRemote", "true"]);
    await git(target, ["config", "--local", `branch.${branch}.base`, base]);
  } catch {
    // The worktree still works; the first push asks for -u.
  }
  const copiedSetupFiles = await copySetupFiles(repo.main, target);

  return { ok: true, worktree: { path: target, branch, base, repoRoot: repo.main, copiedSetupFiles } };
}

// Where a new worktree lives: beside the repository, under one folder per
// repository, one entry per branch (`fix/foo` → `fix-foo`) — so the
// picker's root scan (one level under each root) finds the worktrees
// folder, and nothing is ever created inside the checkout itself.
export function worktreePath(mainWorktree: string, branch: string): string {
  const slug = branch.replace(/[\\/]/g, "-").replace(/[^A-Za-z0-9._-]/g, "-").replace(/-{2,}/g, "-").replace(/^[-.]+|[-.]+$/g, "") || "worktree";
  return path.join(path.dirname(mainWorktree), `${path.basename(mainWorktree)}-worktrees`, slug);
}

// Undo a `worktree add` that failed or timed out part-way: the branch this
// call created and whatever folder git left behind (#81 review).
async function rollBackCreate(main: string, target: string, branch: string): Promise<void> {
  try {
    await git(main, ["worktree", "remove", "--force", target]);
  } catch {
    await fs.rm(target, { recursive: true, force: true }).catch(() => undefined);
    await git(main, ["worktree", "prune"]).catch(() => undefined);
  }
  await git(main, ["branch", "-D", branch]).catch(() => undefined);
}

// The target does not exist yet: its nearest existing ancestor (the
// repository's parent) is realpath'd, as are the roots.
async function withinRootsAfterRealpath(target: string, roots: readonly string[]): Promise<boolean> {
  const realRoots: string[] = [];
  for (const root of roots) {
    try {
      realRoots.push(await fs.realpath(root));
    } catch {
      realRoots.push(root);
    }
  }
  const parent = path.dirname(path.dirname(target));
  let realParent = parent;
  try {
    realParent = await fs.realpath(parent);
  } catch {
    // The parent should exist (it holds the repository); judge lexically.
  }
  const realTarget = path.join(realParent, path.basename(path.dirname(target)), path.basename(target));
  return isWithinRoots(target, roots) || isWithinRoots(realTarget, realRoots);
}

type RepositoryResolution =
  | { ok: true; main: string }
  | { ok: false; status: 400 | 404; error: string };

// The phone's folder → the repository's main worktree, realpath'd. A folder
// that is not inside a repository, or does not exist, is said plainly.
async function resolveRepository(candidate: string): Promise<RepositoryResolution> {
  const trimmed = candidate.trim();
  if (!trimmed || !path.isAbsolute(trimmed) || trimmed.includes("\0")) {
    return { ok: false, status: 400, error: "repo must be an absolute path." };
  }
  let real: string;
  try {
    real = await fs.realpath(trimmed);
  } catch {
    return { ok: false, status: 404, error: "That folder does not exist on this computer." };
  }
  try {
    const { stdout } = await git(real, ["worktree", "list", "--porcelain", "-z"]);
    const main = parseWorktreeList(stdout).find((worktree) => worktree.isMain);
    if (!main) return { ok: false, status: 404, error: "That folder is not inside a git repository." };
    return { ok: true, main: await fs.realpath(main.path) };
  } catch (error) {
    if (/not a git repository/i.test(describeGitError(error))) {
      return { ok: false, status: 404, error: "That folder is not inside a git repository." };
    }
    return { ok: false, status: 404, error: `That folder cannot be read as a git repository: ${describeGitError(error)}` };
  }
}

async function validBranchName(repository: string, branch: string): Promise<boolean> {
  if (branch.startsWith("-")) return false;
  try {
    await git(repository, ["check-ref-format", "--branch", branch]);
    return true;
  } catch {
    return false;
  }
}

async function copySetupFiles(from: string, to: string): Promise<number> {
  let copied = 0;
  let names: string[];
  try {
    names = await fs.readdir(from);
  } catch {
    return 0;
  }
  for (const name of names) {
    if (!SETUP_FILES.includes(name) && !SETUP_PREFIXES.some((prefix) => name.startsWith(prefix))) continue;
    const source = path.join(from, name);
    const destination = path.join(to, name);
    try {
      if ((await fs.lstat(source)).isFile() && !(await exists(destination))) {
        await fs.copyFile(source, destination);
        copied += 1;
      }
    } catch {
      // A file that cannot be copied is not worth failing the worktree over.
    }
  }
  return copied;
}

// MARK: Removal (#81, #73 part 6)
//
// Removing is the one destructive thing this host does to a repository, so
// it is two steps: a preview that names what would be lost, and a removal
// that must repeat those counts back (what the person confirmed is what
// goes). Mechanics as Orca's (research doc §"What to copy"): rename the
// checkout aside first so nothing else can write into it, `worktree remove
// --force` on the renamed folder to deregister it, delete the folder in the
// background, and touch the branch only when it is provably merged — or
// when the person confirmed the exact number of commits they are giving up.

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
  if (!changes.ok) return { ok: false, status: 503, error: `Could not count the uncommitted changes, so nothing was removed: ${changes.error}` };
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
    return { ok: false, status: 503, error: `Could not count the unpushed commits, so nothing was removed: ${describeGitError(error)}` };
  }
  let remote: string | null = null;
  try {
    remote = (await git(worktreePath, ["remote"])).stdout.split("\n").map((line) => line.trim()).filter(Boolean)[0] ?? null;
  } catch {
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

export interface RemoveWorktreeRequest {
  // The counts the person saw; the removal happens only if they still hold.
  confirm: { uncommitted: number; unpushed: number };
  // Push before removing, so no commit is lost (the safe path).
  pushFirst?: boolean | undefined;
  // true: delete the branch even when unmerged (the person confirmed the
  // commit count); false: keep it; absent: delete only when merged or
  // just pushed.
  deleteBranch?: boolean | undefined;
  // A locked worktree (Claude Code locks every one it makes) is refused
  // unless the person chose "Unlock and remove".
  unlock?: boolean | undefined;
}

export interface RemovedWorktree {
  path: string;
  branch: string | null;
  branchDeleted: boolean;
  // The branch left in place, with why in `branchNote`.
  branchKept: string | null;
  branchNote: string | null;
  // Agents inside the worktree whose herdr tabs were closed.
  closedAgents: number;
  pushed: number;
}

export type RemoveWorktreeResult =
  | { ok: true; removed: RemovedWorktree }
  | { ok: false; status: 400 | 404 | 409 | 503; error: string; preview?: RemovalPreview };

const pendingDeletes = new Set<Promise<void>>();

export async function removeWorktree(worktreePath: string, request: RemoveWorktreeRequest, deps: RemovalDeps = {}): Promise<RemoveWorktreeResult> {
  const previewed = await previewRemoval(worktreePath, deps);
  if (!previewed.ok) return previewed;
  const preview = previewed.preview;
  if (preview.isMain) {
    return { ok: false, status: 409, error: `${path.basename(worktreePath)} is the repository's main checkout; it cannot be removed from here.` };
  }
  if (preview.locked) {
    // A lock is a "do not remove" — Claude Code's own worktrees carry one
    // — so it is lifted only on request; prune would otherwise skip the
    // entry and leave the repository pointing at a deleted folder.
    if (!request.unlock) {
      return { ok: false, status: 409, error: `${preview.branch ?? path.basename(worktreePath)} is locked on the computer. Choose "Unlock and remove" if you mean to remove it.`, preview };
    }
    try {
      await git(preview.repoRoot, ["worktree", "unlock", worktreePath]);
    } catch (error) {
      return { ok: false, status: 503, error: `Nothing was removed: git could not unlock the worktree: ${describeGitError(error)}`, preview };
    }
  }
  if (preview.uncommitted.files !== request.confirm.uncommitted || preview.unpushed.commits !== request.confirm.unpushed) {
    return {
      ok: false,
      status: 409,
      error: `${preview.branch ?? path.basename(worktreePath)} changed since you looked: now ${countWords(preview.uncommitted.files, "uncommitted change")} and ${countWords(preview.unpushed.commits, "commit")} not pushed. Look again before removing.`,
      preview,
    };
  }

  let pushed = 0;
  if (request.pushFirst && preview.unpushed.commits > 0) {
    if (!preview.branch) return { ok: false, status: 409, error: "Nothing was removed. This worktree is not on a branch, so its commits cannot be pushed.", preview };
    const push = await pushBranch(worktreePath);
    if (!push.ok) return { ok: false, status: push.status, error: `Nothing was removed. ${push.error}` };
    pushed = push.pushed;
  }

  // Agents first: a pane still living in the folder would keep writing
  // into the renamed checkout (or fail loudly at its next prompt).
  let closedAgents = 0;
  const closedTabs = new Set<string>();
  for (const agent of preview.agents) {
    if (!agent.tabId) continue;
    if (closedTabs.has(agent.tabId)) {
      closedAgents += 1;
      continue;
    }
    try {
      if (deps.closeTab && (await deps.closeTab(agent.tabId))) {
        closedTabs.add(agent.tabId);
        closedAgents += 1;
      }
    } catch {
      // Herdr away: the worktree still goes; the pane will say so itself.
    }
  }

  const aside = leftoverName(worktreePath);
  try {
    await fs.rename(worktreePath, aside);
  } catch (error) {
    return { ok: false, status: 503, error: `The worktree folder could not be moved aside: ${error instanceof Error ? error.message : String(error)}` };
  }
  // Deregistration: the registered path is gone, so `worktree prune`
  // drops the entry (`worktree remove` would refuse the moved folder).
  // The folder itself is deleted in the background — it can be large.
  try {
    await git(preview.repoRoot, ["worktree", "prune"]);
  } catch (error) {
    console.error(`tavi: git worktree prune failed after removing ${worktreePath}: ${describeGitError(error)}`);
  }
  const deletion = fs.rm(aside, { recursive: true, force: true }).then(
    () => undefined,
    (error: unknown) => {
      // Said on the log now; retried by the hourly sweep and named by
      // `tavi doctor` until it goes (#82).
      console.error(`tavi: could not delete ${aside} after removing the worktree (it will be retried; tavi doctor lists it): ${error instanceof Error ? error.message : String(error)}`);
    },
  );
  pendingDeletes.add(deletion);
  void deletion.finally(() => pendingDeletes.delete(deletion));

  let branchDeleted = false;
  let branchKept: string | null = null;
  let branchNote: string | null = null;
  if (preview.branch) {
    // Deleted only on live proof the commits live elsewhere — merged into
    // the base, or pushed by this very call — or when the person confirmed
    // the exact commit count away. A local remote-tracking ref is not
    // proof: it may be stale (#81 review).
    const wantDelete = request.deleteBranch === true || (request.deleteBranch !== false && (preview.branchMerged || pushed > 0));
    if (wantDelete) {
      const force = !preview.branchMerged;
      try {
        await git(preview.repoRoot, ["branch", force ? "-D" : "-d", preview.branch]);
        branchDeleted = true;
      } catch (error) {
        branchKept = preview.branch;
        branchNote = `git kept the branch: ${describeGitError(error).split("\n")[0]}`;
      }
    } else {
      branchKept = preview.branch;
      branchNote = preview.unpushed.commits > 0
        ? `${countWords(preview.unpushed.commits, "commit")} on ${preview.branch} exist nowhere else, so the branch stays.`
        : preview.unpushed.upstream
          ? `${preview.branch} stays here; it is on ${preview.unpushed.upstream} too.`
          : `${preview.branch} is not merged into ${preview.base ?? "its base"}, so the branch stays.`;
    }
  }

  return {
    ok: true,
    removed: { path: worktreePath, branch: preview.branch, branchDeleted, branchKept, branchNote, closedAgents, pushed },
  };
}

async function countCommits(cwd: string, revisions: string[]): Promise<number> {
  const { stdout } = await git(cwd, ["rev-list", "--count", ...revisions]);
  return Number.parseInt(stdout.trim(), 10) || 0;
}

// Tests wait for the background delete; the route never does. A delete
// that fails is logged above and the `.removing-*` folder is left for a
// person to look at (#82 sweeps them).
export async function awaitPendingDeletes(): Promise<void> {
  await Promise.all([...pendingDeletes]);
}

type Located = { ok: true; main: string; isMain: boolean; locked: boolean } | { ok: false; status: 404 | 503; error: string };

async function locateWorktree(worktreePath: string): Promise<Located> {
  let listed: ReturnType<typeof parseWorktreeList>;
  try {
    listed = parseWorktreeList((await git(worktreePath, ["worktree", "list", "--porcelain", "-z"])).stdout);
  } catch (error) {
    if (/not a git repository/i.test(describeGitError(error))) return { ok: false, status: 404, error: "That folder is not inside a git repository." };
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
      continue;
    }
    if (worktree.isMain) mainReal = real;
    if (real === worktreePath) match = worktree;
  }
  if (!match) return { ok: false, status: 404, error: "That folder is not a worktree of its repository — only a whole worktree can be removed." };
  return { ok: true, main: mainReal, isMain: match.isMain, locked: match.locked };
}

async function isAncestor(cwd: string, branch: string, base: string): Promise<boolean> {
  try {
    await git(cwd, ["merge-base", "--is-ancestor", branch, base]);
    return true;
  } catch {
    return false;
  }
}

async function agentsInside(worktreePath: string, deps: RemovalDeps): Promise<{ inside: RemovalAgent[]; alsoClosed: RemovalAgent[] }> {
  const none = { inside: [], alsoClosed: [] };
  if (!deps.agents) return none;
  let agents: HerdrAgentInfo[];
  try {
    agents = await deps.agents();
  } catch {
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

function countWords(count: number, noun: string): string {
  return `${count} ${noun}${count === 1 ? "" : "s"}`;
}

async function exists(target: string): Promise<boolean> {
  try {
    await fs.lstat(target);
    return true;
  } catch {
    return false;
  }
}
