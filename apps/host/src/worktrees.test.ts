import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { createWorktree, worktreePath } from "./worktrees.js";

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
