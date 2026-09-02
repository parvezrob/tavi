import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import type { HerdrAgentInfo } from "./types.js";
import { awaitPendingDeletes, createWorktree, previewRemoval, removeWorktree, worktreePath } from "./worktrees.js";

function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", ["-C", cwd, ...args], {
    encoding: "utf8",
    env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" },
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
  assert.equal(worktreePath("/Users/me/Projects/app", "fix/login redirect"), "/Users/me/Projects/app-worktrees/fix-login-redirect");
});

test("createWorktree adds the branch off the default base, sets the configs, copies .env (#75)", async () => {
  const { dir, parent } = repo();
  const result = await createWorktree({ repo: path.join(dir, "src-does-not-matter", ".."), branch: "fix/foo" }, [parent], { allowOutsideRoots: false });
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

  const base = await createWorktree({ repo: dir, branch: "fix/bar", base: "nope" }, [parent], { allowOutsideRoots: false });
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
  return { id: `p-${tabId}`, agent: "claude", status: "done", cwd, title: "", workspaceId: "w", tabId, focused: false, revision: 1, authority: "herdr" } as HerdrAgentInfo;
}

test("removal preview names the uncommitted files, the unpushed commits, the agents inside, and whether the branch is merged", async () => {
  const { dir, wt } = await removable();
  // One agent in the worktree, one in the main checkout, one whose cwd is gone.
  const preview = await previewRemoval(wt, { agents: async () => [agent(wt, "t1"), agent(dir, "t2"), agent(path.join(wt, "vanished"), "t3")] });
  assert.ok(preview.ok, JSON.stringify(preview));
  assert.equal(preview.preview.branch, "feat/gone");
  assert.equal(preview.preview.isMain, false);
  assert.equal(preview.preview.uncommitted.files, 1);
  assert.equal(preview.preview.uncommitted.additions, 1);
  assert.deepEqual(preview.preview.unpushed, { commits: 1, upstream: null, remote: "origin" });
  assert.deepEqual(preview.preview.agents.map((a) => a.tabId), ["t1"]);
  assert.equal(preview.preview.branchMerged, false);

  const main = await previewRemoval(dir);
  assert.ok(main.ok);
  assert.equal(main.preview.isMain, true);
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
    { agents: async () => [agent(wt, "t1"), agent(wt, "t1"), agent(wt, "t3")], closeTab: async (tabId) => { closed.push(tabId); return true; } },
  );
  assert.ok(result.ok, JSON.stringify(result));
  assert.equal(result.removed.pushed, 1);
  assert.equal(result.removed.closedAgents, 2);
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
