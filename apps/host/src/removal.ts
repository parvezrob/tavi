import { promises as fs } from "node:fs";
import path from "node:path";
import { pushBranch } from "./commits.js";
import { describeGitError, git } from "./git-exec.js";
import { log } from "./log.js";
import { previewRemoval, type RemovalDeps, type RemovalPreview } from "./removal-preview.js";
import { leftoverName } from "./removal-sweep.js";

// Removing a worktree (#81, #73 part 6). The destructive half of the two
// steps `removal-preview.ts` opens: what the person confirmed is what goes,
// and the counts they saw must still hold. Mechanics as Orca's (research
// doc §"What to copy"): rename the checkout aside first so nothing else can
// write into it, `worktree prune` to deregister it, delete the folder in
// the background, and touch the branch only when it is provably merged —
// or when the person confirmed the exact number of commits they give up.

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

export async function removeWorktree(
  worktreePath: string,
  request: RemoveWorktreeRequest,
  deps: RemovalDeps = {},
): Promise<RemoveWorktreeResult> {
  const previewed = await previewRemoval(worktreePath, deps);
  if (!previewed.ok) return previewed;
  const preview = previewed.preview;
  if (preview.isMain) {
    return {
      ok: false,
      status: 409,
      error: `${path.basename(worktreePath)} is the repository's main checkout; it cannot be removed from here.`,
    };
  }
  if (preview.locked) {
    // A lock is a "do not remove" — Claude Code's own worktrees carry one
    // — so it is lifted only on request; prune would otherwise skip the
    // entry and leave the repository pointing at a deleted folder.
    if (!request.unlock) {
      return {
        ok: false,
        status: 409,
        error: `${preview.branch ?? path.basename(worktreePath)} is locked on the computer. Choose "Unlock and remove" if you mean to remove it.`,
        preview,
      };
    }
    try {
      await git(preview.repoRoot, ["worktree", "unlock", worktreePath]);
    } catch (error) {
      return {
        ok: false,
        status: 503,
        error: `Nothing was removed: git could not unlock the worktree: ${describeGitError(error)}`,
        preview,
      };
    }
  }
  if (
    preview.uncommitted.files !== request.confirm.uncommitted ||
    preview.unpushed.commits !== request.confirm.unpushed
  ) {
    return {
      ok: false,
      status: 409,
      error: `${preview.branch ?? path.basename(worktreePath)} changed since you looked: now ${countWords(preview.uncommitted.files, "uncommitted change")} and ${countWords(preview.unpushed.commits, "commit")} not pushed. Look again before removing.`,
      preview,
    };
  }

  let pushed = 0;
  if (request.pushFirst && preview.unpushed.commits > 0) {
    if (!preview.branch)
      return {
        ok: false,
        status: 409,
        error: "Nothing was removed. This worktree is not on a branch, so its commits cannot be pushed.",
        preview,
      };
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
    return {
      ok: false,
      status: 503,
      error: `The worktree folder could not be moved aside: ${error instanceof Error ? error.message : String(error)}`,
    };
  }
  // Deregistration: the registered path is gone, so `worktree prune`
  // drops the entry (`worktree remove` would refuse the moved folder).
  // The folder itself is deleted in the background — it can be large.
  try {
    await git(preview.repoRoot, ["worktree", "prune"]);
  } catch (error) {
    log.error("worktrees", `git worktree prune failed after removing ${worktreePath}: ${describeGitError(error)}`);
  }
  const deletion = fs.rm(aside, { recursive: true, force: true }).then(
    () => undefined,
    (error: unknown) => {
      // Said on the log now; retried by the hourly sweep and named by
      // `tavi doctor` until it goes (#82).
      log.error(
        "worktrees",
        `could not delete ${aside} after removing the worktree (it will be retried; tavi doctor lists it): ${error instanceof Error ? error.message : String(error)}`,
      );
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
    const wantDelete =
      request.deleteBranch === true || (request.deleteBranch !== false && (preview.branchMerged || pushed > 0));
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
      branchNote =
        preview.unpushed.commits > 0
          ? `${countWords(preview.unpushed.commits, "commit")} on ${preview.branch} exist nowhere else, so the branch stays.`
          : preview.unpushed.upstream
            ? `${preview.branch} stays here; it is on ${preview.unpushed.upstream} too.`
            : `${preview.branch} is not merged into ${preview.base ?? "its base"}, so the branch stays.`;
    }
  }

  return {
    ok: true,
    removed: {
      path: worktreePath,
      branch: preview.branch,
      branchDeleted,
      branchKept,
      branchNote,
      closedAgents,
      pushed,
    },
  };
}

// Tests wait for the background delete; the route never does. A delete
// that fails is logged above and the `.removing-*` folder is left for a
// person to look at (#82 sweeps them).
export async function awaitPendingDeletes(): Promise<void> {
  await Promise.all([...pendingDeletes]);
}

function countWords(count: number, noun: string): string {
  return `${count} ${noun}${count === 1 ? "" : "s"}`;
}
