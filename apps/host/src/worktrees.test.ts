import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import type { HerdrAgentInfo } from "./types.js";
import { previewRemoval } from "./removal-preview.js";
import { awaitPendingDeletes, removeWorktree } from "./removal.js";
import { createWorktree, worktreePath } from "./worktrees.js";

function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", ["-C", cwd, ...args], {
    encoding: "utf8",
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: "t",
      GIT_AUTHOR_EMAIL: "t@t",
      GIT_COMMITTER_NAME: "t",
      GIT_COMMITTER_EMAIL: "t@t",
    },
  });
}

// One repo per test under a fresh, realpath'd parent (the #57 trap: macOS
// /var → /private/var), with a committed README and an ignored .env.
function repo(): { dir: string; parent: string } {
  const parent = realpathSync(mkdtempSync(path.join(tmpdir(), "tavi-wt-")));
  const dir = path.join(parent, "repo");
  git(parent, "init", "-q", "-b", "main", "repo");
  writeFileSync(path.join(dir, "README.md"), "hello\n");
  writeFileSync(path.join(dir, ".gitignore"), ".env\n");
  writeFileSync(path.join(dir, ".env"), "SECRET=1\n");
  git(dir, "add", ".");
  git(dir, "commit", "-q", "-m", "init");
  return { dir, parent };
}

test("worktreePath sits beside the repository, one folder per repo, slash → dash", () => {
  assert.equal(
    worktreePath("/Users/me/Projects/app", "fix/login redirect"),
    "/Users/me/Projects/app-worktrees/fix-login-redirect",
  );
  // Punctuation never leaves a leading dash or a run of them (owner saw
  // "(test)worktree" become "-test-worktree").
  assert.equal(
    worktreePath("/Users/me/Projects/app", "(test)worktree"),
    "/Users/me/Projects/app-worktrees/test-worktree",
  );
  assert.equal(worktreePath("/Users/me/Projects/app", "--- ---"), "/Users/me/Projects/app-worktrees/worktree");
});

test("createWorktree adds the branch off the default base, sets the configs, copies .env (#75)", async () => {
  const { dir, parent } = repo();
  const result = await createWorktree(
    { repo: path.join(dir, "src-does-not-matter", ".."), branch: "fix/foo" },
    [parent],
    { allowOutsideRoots: false },
  );
  assert.ok(result.ok, JSON.stringify(result));
  const created = result.worktree;
  assert.equal(created.path, path.join(parent, "repo-worktrees", "fix-foo"));
  assert.equal(created.branch, "fix/foo");
  assert.equal(created.base, "main");
  assert.equal(created.repoRoot, dir);
  assert.equal(created.copiedSetupFiles, 1);
  assert.equal(git(created.path, "rev-parse", "--abbrev-ref", "HEAD").trim(), "fix/foo");
  assert.equal(git(created.path, "config", "--local", "push.autoSetupRemote").trim(), "true");
  assert.equal(git(created.path, "config", "--local", "branch.fix/foo.base").trim(), "main");
  assert.equal(readFileSync(path.join(created.path, ".env"), "utf8"), "SECRET=1\n");
  // --no-track: no upstream, so status never says "behind".
  assert.throws(() => git(created.path, "rev-parse", "--abbrev-ref", "fix/foo@{upstream}"));
});

// Skipped as root, where a mode of 000 stops nothing.
test("a setup file that cannot be copied is named in the result, never reported as 0 copied (#98)", {
  skip: process.getuid?.() === 0,
}, async () => {
  const { dir, parent } = repo();
  // Unreadable to its own owner: `copyFile` fails with EACCES, exactly as a
  // `.env` written by another user under a shared checkout would.
  chmodSync(path.join(dir, ".env"), 0o000);
  try {
    const result = await createWorktree({ repo: dir, branch: "fix/perms" }, [parent], { allowOutsideRoots: false });
    assert.ok(result.ok, JSON.stringify(result));
    assert.equal(result.worktree.copiedSetupFiles, 0);
    assert.match(result.worktree.setupFilesFailed ?? "", /1 setup file could not be copied/);
    assert.match(result.worktree.setupFilesFailed ?? "", /EACCES/);
    // The names of the files never travel, only how many and why.
    assert.doesNotMatch(result.worktree.setupFilesFailed ?? "", /\.env/);
    assert.ok(!existsSync(path.join(result.worktree.path, ".env")));
  } finally {
    chmodSync(path.join(dir, ".env"), 0o600);
  }
});

test("createWorktree refuses an existing branch, a bad name, a missing base, and a folder that is not a repo", async () => {
  const { dir, parent } = repo();
  const dup = await createWorktree({ repo: dir, branch: "main" }, [parent], { allowOutsideRoots: false });
  assert.equal(dup.ok, false);
  if (!dup.ok) assert.equal(dup.status, 409);

  const bad = await createWorktree({ repo: dir, branch: "bad..name" }, [parent], { allowOutsideRoots: false });
  assert.equal(bad.ok, false);
  if (!bad.ok) assert.equal(bad.status, 400);

  const flag = await createWorktree({ repo: dir, branch: "--upload-pack=x" }, [parent], { allowOutsideRoots: false });
  assert.equal(flag.ok, false);
  if (!flag.ok) assert.equal(flag.status, 400);

  const base = await createWorktree({ repo: dir, branch: "fix/bar", base: "nope" }, [parent], {
    allowOutsideRoots: false,
  });
  assert.equal(base.ok, false);
  if (!base.ok) assert.equal(base.status, 400);

  const plain = await createWorktree({ repo: parent, branch: "fix/bar" }, [parent], { allowOutsideRoots: false });
  assert.equal(plain.ok, false);
  if (!plain.ok) assert.equal(plain.status, 404);

  assert.equal(existsSync(path.join(parent, "repo-worktrees")), false);
});

test("createWorktree asks before creating outside the roots, then does it when confirmed", async () => {
  const { dir, parent } = repo();
  // The root is the repository itself: its sibling worktrees folder is outside.
  const refused = await createWorktree({ repo: dir, branch: "fix/out" }, [dir], { allowOutsideRoots: false });
  assert.equal(refused.ok, false);
  if (!refused.ok) {
    assert.equal(refused.status, 400);
    assert.equal(refused.outsideRoots, true);
  }
  const confirmed = await createWorktree({ repo: dir, branch: "fix/out" }, [dir], { allowOutsideRoots: true });
  assert.ok(confirmed.ok);
  assert.equal(existsSync(path.join(parent, "repo-worktrees", "fix-out", "README.md")), true);
});

// MARK: Removal (#81)

// A worktree off main with one commit, one uncommitted file, and a bare
// remote that has main only. Returns the paths the tests need.
async function removable(): Promise<{ dir: string; parent: string; wt: string }> {
  const { dir, parent } = repo();
  git(parent, "init", "-q", "--bare", "remote.git");
  git(dir, "remote", "add", "origin", path.join(parent, "remote.git"));
  git(dir, "push", "-q", "origin", "main");
  const created = await createWorktree({ repo: dir, branch: "feat/gone" }, [parent], { allowOutsideRoots: false });
  assert.ok(created.ok, JSON.stringify(created));
  const wt = created.worktree.path;
  writeFileSync(path.join(wt, "new.txt"), "new\n");
  git(wt, "add", "new.txt");
  git(wt, "commit", "-q", "-m", "feat: new");
  writeFileSync(path.join(wt, "README.md"), "hello\nchanged\n");
  return { dir, parent, wt };
}

function agent(cwd: string, tabId: string): HerdrAgentInfo {
  return {
    id: `p-${tabId}`,
    agent: "claude",
    status: "done",
    cwd,
    title: "",
    workspaceId: "w",
    tabId,
    focused: false,
    revision: 1,
    authority: "herdr",
  } as HerdrAgentInfo;
}

test("removal preview names the uncommitted files, the unpushed commits, the agents inside, and whether the branch is merged", async () => {
  const { dir, wt } = await removable();
  // One agent in the worktree, one in the main checkout, one whose cwd is gone.
  const preview = await previewRemoval(wt, {
    agents: async () => [agent(wt, "t1"), agent(dir, "t2"), agent(path.join(wt, "vanished"), "t3")],
  });
  assert.ok(preview.ok, JSON.stringify(preview));
  assert.equal(preview.preview.branch, "feat/gone");
  assert.equal(preview.preview.isMain, false);
  assert.equal(preview.preview.uncommitted.files, 1);
  assert.equal(preview.preview.uncommitted.additions, 1);
  assert.deepEqual(preview.preview.unpushed, { commits: 1, upstream: null, remote: "origin" });
  assert.deepEqual(
    preview.preview.agents.map((a) => a.tabId),
    ["t1"],
  );
  assert.deepEqual(preview.preview.alsoClosed, []);
  assert.equal(preview.preview.branchMerged, false);
  assert.equal(preview.preview.locked, false);

  // herdr closes tabs: an agent elsewhere that shares tab t1 with the one
  // inside goes down too, and the preview names it (#83).
  const shared = await previewRemoval(wt, {
    agents: async () => [agent(wt, "t1"), agent(dir, "t1"), agent(dir, "t2")],
  });
  assert.ok(shared.ok);
  assert.deepEqual(
    shared.preview.agents.map((a) => a.tabId),
    ["t1"],
  );
  assert.deepEqual(
    shared.preview.alsoClosed.map((a) => [a.tabId, a.cwd]),
    [["t1", dir]],
  );

  const main = await previewRemoval(dir);
  assert.ok(main.ok);
  assert.equal(main.preview.isMain, true);
});

test("removal counts a detached worktree's orphan commits, refuses a locked worktree, and refuses rather than guessing when git cannot count", async () => {
  const { dir, parent } = repo();
  const detached = path.join(parent, "detached");
  git(dir, "worktree", "add", "-q", "--detach", detached);
  writeFileSync(path.join(detached, "d.txt"), "d\n");
  git(detached, "add", "d.txt");
  git(detached, "commit", "-q", "-m", "important work");
  const preview = await previewRemoval(detached);
  assert.ok(preview.ok, JSON.stringify(preview));
  assert.equal(preview.preview.branch, null);
  assert.equal(preview.preview.unpushed.commits, 1);
  const wrong = await removeWorktree(detached, { confirm: { uncommitted: 0, unpushed: 0 } });
  assert.equal(wrong.ok, false);
  assert.ok(existsSync(detached));

  const locked = await removable();
  git(locked.dir, "worktree", "lock", locked.wt);
  const lockedPreview = await previewRemoval(locked.wt);
  assert.ok(lockedPreview.ok);
  assert.equal(lockedPreview.preview.locked, true);
  const refused = await removeWorktree(locked.wt, { confirm: { uncommitted: 1, unpushed: 1 }, deleteBranch: true });
  assert.equal(refused.ok, false);
  if (!refused.ok) {
    assert.equal(refused.status, 409);
    assert.match(refused.error, /locked/);
  }
  assert.ok(existsSync(locked.wt));
  assert.equal(git(locked.dir, "worktree", "list").split("\n").filter(Boolean).length, 2);
  // "Unlock and remove" lifts the lock first, then removes as usual.
  const unlocked = await removeWorktree(locked.wt, {
    confirm: { uncommitted: 1, unpushed: 1 },
    deleteBranch: true,
    unlock: true,
  });
  assert.ok(unlocked.ok, JSON.stringify(unlocked));
  await awaitPendingDeletes();
  assert.equal(existsSync(locked.wt), false);
  assert.equal(git(locked.dir, "worktree", "list").split("\n").filter(Boolean).length, 1);

  // An unreadable index: the preview must refuse, never say "clean".
  const broken = await removable();
  const index = git(broken.wt, "rev-parse", "--git-path", "index").trim();
  writeFileSync(path.isAbsolute(index) ? index : path.join(broken.wt, index), "garbage");
  const unknown = await previewRemoval(broken.wt);
  assert.equal(unknown.ok, false);
  if (!unknown.ok) assert.match(unknown.error, /nothing was removed/);
  const blocked = await removeWorktree(broken.wt, { confirm: { uncommitted: 0, unpushed: 0 } });
  assert.equal(blocked.ok, false);
  assert.ok(existsSync(broken.wt));
});

test("a branch fully on a stale upstream is kept, not deleted, when its worktree goes", async () => {
  const { dir, wt } = await removable();
  git(wt, "push", "-q", "--set-upstream", "origin", "feat/gone");
  git(wt, "checkout", "-q", "--", "README.md");
  const preview = await previewRemoval(wt);
  assert.ok(preview.ok);
  assert.equal(preview.preview.unpushed.commits, 0);
  assert.equal(preview.preview.unpushed.upstream, "origin/feat/gone");
  const result = await removeWorktree(wt, { confirm: { uncommitted: 0, unpushed: 0 } });
  assert.ok(result.ok, JSON.stringify(result));
  assert.equal(result.removed.branchDeleted, false);
  assert.equal(result.removed.branchKept, "feat/gone");
  assert.match(result.removed.branchNote ?? "", /on origin\/feat\/gone too/);
  await awaitPendingDeletes();
  assert.equal(git(dir, "branch", "--list", "feat/gone").trim(), "feat/gone");
});

test("a worktree add that fails part-way is rolled back: no branch, no folder, nothing registered", async () => {
  const { dir, parent } = repo();
  // A post-checkout hook that fails makes `worktree add` exit non-zero
  // after the branch and folder exist.
  const hooks = path.join(dir, ".git", "hooks");
  writeFileSync(path.join(hooks, "post-checkout"), "#!/bin/sh\nexit 1\n", { mode: 0o755 });
  const result = await createWorktree({ repo: dir, branch: "feat/hooked" }, [parent], { allowOutsideRoots: false });
  assert.equal(result.ok, false);
  if (!result.ok) assert.equal(result.status, 503);
  assert.equal(git(dir, "branch", "--list", "feat/hooked").trim(), "");
  assert.equal(existsSync(path.join(parent, "repo-worktrees", "feat-hooked")), false);
  assert.equal(git(dir, "worktree", "list").split("\n").filter(Boolean).length, 1);
});

test("removal refuses the main checkout, stale counts, and a folder that is not a worktree — touching nothing", async () => {
  const { dir, parent, wt } = await removable();
  const main = await removeWorktree(dir, { confirm: { uncommitted: 0, unpushed: 0 } });
  assert.equal(main.ok, false);
  if (!main.ok) assert.equal(main.status, 409);

  const stale = await removeWorktree(wt, { confirm: { uncommitted: 0, unpushed: 1 } });
  assert.equal(stale.ok, false);
  if (!stale.ok) {
    assert.equal(stale.status, 409);
    assert.match(stale.error, /changed since you looked/);
    assert.equal(stale.preview?.uncommitted.files, 1);
  }
  assert.ok(existsSync(wt));
  assert.equal(git(dir, "worktree", "list").split("\n").filter(Boolean).length, 2);

  const notWorktree = await removeWorktree(parent, { confirm: { uncommitted: 0, unpushed: 0 } });
  assert.equal(notWorktree.ok, false);
  if (!notWorktree.ok) assert.equal(notWorktree.status, 404);
});

test("push-then-remove pushes, closes the agents, moves the folder aside, deregisters, and drops the pushed branch", async () => {
  const { dir, parent, wt } = await removable();
  const closed: string[] = [];
  const result = await removeWorktree(
    wt,
    { confirm: { uncommitted: 1, unpushed: 1 }, pushFirst: true },
    {
      agents: async () => [agent(wt, "t1"), agent(wt, "t1"), agent(wt, "t3")],
      closeTab: async (tabId) => {
        closed.push(tabId);
        return true;
      },
    },
  );
  assert.ok(result.ok, JSON.stringify(result));
  assert.equal(result.removed.pushed, 1);
  // Three agents inside, two tabs: every agent counts, each tab closes once.
  assert.equal(result.removed.closedAgents, 3);
  assert.deepEqual(closed.sort(), ["t1", "t3"]);
  assert.equal(result.removed.branchDeleted, true);
  assert.equal(git(path.join(parent, "remote.git"), "rev-parse", "refs/heads/feat/gone").trim().length, 40);
  await awaitPendingDeletes();
  assert.equal(existsSync(wt), false);
  assert.equal(git(dir, "worktree", "list").split("\n").filter(Boolean).length, 1);
  assert.equal(git(dir, "branch", "--list", "feat/gone").trim(), "");
});

test("discard removes with the confirmed counts; the unmerged branch is kept unless its commits were confirmed away", async () => {
  const kept = await removable();
  const keep = await removeWorktree(kept.wt, { confirm: { uncommitted: 1, unpushed: 1 } });
  assert.ok(keep.ok, JSON.stringify(keep));
  assert.equal(keep.removed.branchDeleted, false);
  assert.equal(keep.removed.branchKept, "feat/gone");
  assert.match(keep.removed.branchNote ?? "", /exist nowhere else/);
  await awaitPendingDeletes();
  assert.equal(existsSync(kept.wt), false);
  assert.equal(git(kept.dir, "branch", "--list", "feat/gone").trim(), "feat/gone");

  const gone = await removable();
  const discard = await removeWorktree(gone.wt, { confirm: { uncommitted: 1, unpushed: 1 }, deleteBranch: true });
  assert.ok(discard.ok, JSON.stringify(discard));
  assert.equal(discard.removed.branchDeleted, true);
  await awaitPendingDeletes();
  assert.equal(git(gone.dir, "branch", "--list", "feat/gone").trim(), "");
});

test("a clean, merged worktree removes quietly and its branch goes with it", async () => {
  const { dir, parent } = repo();
  const created = await createWorktree({ repo: dir, branch: "feat/merged" }, [parent], { allowOutsideRoots: false });
  assert.ok(created.ok);
  const preview = await previewRemoval(created.worktree.path);
  assert.ok(preview.ok);
  assert.equal(preview.preview.uncommitted.files, 0);
  assert.equal(preview.preview.unpushed.commits, 0);
  assert.equal(preview.preview.branchMerged, true);
  const result = await removeWorktree(created.worktree.path, { confirm: { uncommitted: 0, unpushed: 0 } });
  assert.ok(result.ok, JSON.stringify(result));
  assert.equal(result.removed.branchDeleted, true);
  await awaitPendingDeletes();
  assert.equal(git(dir, "branch", "--list", "feat/merged").trim(), "");
});
