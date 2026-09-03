import { promises as fs } from "node:fs";
import path from "node:path";
import { describeGitError, git } from "./git-exec.js";
import { parseWorktreeList } from "./git.js";
import { findDefaultBranch, refExists } from "./git-refs.js";
import { isWithinRoots } from "./projects.js";

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
  // Why some (or all) of them did not make it, as a sentence (#98). Absent
  // when the copy ran clean: a permission error must not read as "0 files
  // copied", which is what a repository with no setup files looks like.
  setupFilesFailed?: string;
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
      return {
        ok: false,
        status: 400,
        error: `There is no branch or commit named ${base} in ${path.basename(repo.main)}.`,
      };
    }
  } else {
    base = await findDefaultBranch(repo.main);
    if (!base) {
      return {
        ok: false,
        status: 400,
        error: `${path.basename(repo.main)} has no main or master branch to start from; name a base.`,
      };
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
    await git(
      repo.main,
      ["worktree", "add", "--no-track", "-b", branch, target, base],
      undefined,
      [0],
      WORKTREE_ADD_TIMEOUT_MS,
    );
  } catch (error) {
    const reason = describeGitError(error);
    await rollBackCreate(repo.main, target, branch);
    const timedOut =
      /SIGTERM|ETIMEDOUT/i.test(error instanceof Error ? error.message : "") && !/fatal:|error:/i.test(reason);
    return {
      ok: false,
      status: 503,
      error: timedOut
        ? `git took longer than ${WORKTREE_ADD_TIMEOUT_MS / 1000} s to create the worktree, so it was rolled back. Try again on the computer.`
        : `git could not create the worktree: ${reason}`,
    };
  }
  // Best effort after the worktree exists: a failed config write is not
  // worth a half-made worktree the phone was never told about.
  try {
    await git(target, ["config", "--local", "push.autoSetupRemote", "true"]);
    await git(target, ["config", "--local", `branch.${branch}.base`, base]);
  } catch {
    // The worktree still works; the first push asks for -u.
  }
  const setup = await copySetupFiles(repo.main, target);

  return {
    ok: true,
    worktree: {
      path: target,
      branch,
      base,
      repoRoot: repo.main,
      copiedSetupFiles: setup.copied,
      ...(setup.failed ? { setupFilesFailed: setup.failed } : {}),
    },
  };
}

// Where a new worktree lives: beside the repository, under one folder per
// repository, one entry per branch (`fix/foo` → `fix-foo`) — so the
// picker's root scan (one level under each root) finds the worktrees
// folder, and nothing is ever created inside the checkout itself.
export function worktreePath(mainWorktree: string, branch: string): string {
  const slug =
    branch
      .replace(/[\\/]/g, "-")
      .replace(/[^A-Za-z0-9._-]/g, "-")
      .replace(/-{2,}/g, "-")
      .replace(/^[-.]+|[-.]+$/g, "") || "worktree";
  return path.join(path.dirname(mainWorktree), `${path.basename(mainWorktree)}-worktrees`, slug);
}

// Undo a `worktree add` that failed or timed out part-way: the branch this
// call created and whatever folder git left behind (#81 review).
async function rollBackCreate(main: string, target: string, branch: string): Promise<void> {
  try {
    await git(main, ["worktree", "remove", "--force", target]);
  } catch {
    // `worktree remove` refuses a half-made checkout; the rollback then
    // deletes the folder itself and prunes the registration.
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
      // A root that does not resolve is judged as written; containment is
      // then decided on the lexical path, never skipped.
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

type RepositoryResolution = { ok: true; main: string } | { ok: false; status: 400 | 404; error: string };

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
    // Not swallowed: a path that will not realpath is a 404 with the
    // sentence a person can act on.
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
    return {
      ok: false,
      status: 404,
      error: `That folder cannot be read as a git repository: ${describeGitError(error)}`,
    };
  }
}

async function validBranchName(repository: string, branch: string): Promise<boolean> {
  if (branch.startsWith("-")) return false;
  try {
    await git(repository, ["check-ref-format", "--branch", branch]);
    return true;
  } catch {
    // `check-ref-format` exits non-zero for an invalid name, which is the
    // question; the caller refuses with the name it was given.
    return false;
  }
}

// A file that cannot be copied is not worth failing the worktree over, but
// it is worth saying: a `.env` the new checkout needs and did not get is
// why the first `npm run dev` there fails, and "0 files copied" alone is
// indistinguishable from a repository that has no setup files (#98). The
// names never travel — only how many and why (the redaction rule).
async function copySetupFiles(from: string, to: string): Promise<{ copied: number; failed: string | null }> {
  let copied = 0;
  let names: string[];
  try {
    names = await fs.readdir(from);
  } catch (error) {
    return { copied: 0, failed: `The repository's own folder could not be read (${reason(error)}).` };
  }
  let missed = 0;
  let firstReason = "";
  for (const name of names) {
    if (!SETUP_FILES.includes(name) && !SETUP_PREFIXES.some((prefix) => name.startsWith(prefix))) continue;
    const source = path.join(from, name);
    const destination = path.join(to, name);
    try {
      if ((await fs.lstat(source)).isFile() && !(await exists(destination))) {
        await fs.copyFile(source, destination);
        copied += 1;
      }
    } catch (error) {
      missed += 1;
      if (!firstReason) firstReason = reason(error);
    }
  }
  if (missed === 0) return { copied, failed: null };
  return {
    copied,
    failed: `${missed} setup file${missed === 1 ? "" : "s"} could not be copied into the new worktree (${firstReason}).`,
  };
}

// The error's code, never its message: a copy failure names the file it
// could not read, and a path is not ours to hand back (the redaction rule).
function reason(error: unknown): string {
  const code = (error as { code?: unknown }).code;
  return typeof code === "string" ? code : "unknown error";
}

async function exists(target: string): Promise<boolean> {
  try {
    await fs.lstat(target);
    return true;
  } catch {
    // lstat fails only when there is nothing there, which is the answer.
    return false;
  }
}
