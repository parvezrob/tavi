import { promises as fs } from "node:fs";
import path from "node:path";
import { describeGitError, git } from "./git-exec.js";
import { findDefaultBranch, parseWorktreeList, refExists } from "./git.js";
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
  if (!isWithinRoots(target, roots) && !options.allowOutsideRoots) {
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
    await git(repo.main, ["worktree", "add", "--no-track", "-b", branch, target, base]);
  } catch (error) {
    return { ok: false, status: 503, error: `git could not create the worktree: ${describeGitError(error)}` };
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
  const slug = branch.replace(/[\\/]/g, "-").replace(/[^A-Za-z0-9._-]/g, "-");
  return path.join(path.dirname(mainWorktree), `${path.basename(mainWorktree)}-worktrees`, slug);
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
    const { stdout } = await git(real, ["worktree", "list", "--porcelain"]);
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

async function exists(target: string): Promise<boolean> {
  try {
    await fs.lstat(target);
    return true;
  } catch {
    return false;
  }
}
