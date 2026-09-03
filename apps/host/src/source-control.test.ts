import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
  commitStaged,
  pullBase,
  pushBranch,
  stageFiles,
  worktreeLog,
  worktreeStatus,
  writeCommitMessage,
} from "./source-control.js";

const identity = { GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" };

function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8", env: { ...process.env, ...identity } });
}

function repo(): string {
  const parent = realpathSync(mkdtempSync(path.join(tmpdir(), "tavi-sc-")));
  const dir = path.join(parent, "repo");
  git(parent, "init", "-q", "-b", "main", "repo");
  // The module commits as the repository's user, not with this file's env
  // — on a machine with no global identity (CI) that must still work.
  git(dir, "config", "user.name", "t");
  git(dir, "config", "user.email", "t@t");
  writeFileSync(path.join(dir, "a.txt"), "one\n");
  git(dir, "add", ".");
  git(dir, "commit", "-q", "-m", "init");
  return dir;
}

test("status lists changes with the branch, base, ahead/behind, and the staged count", async () => {
  const dir = repo();
  git(dir, "checkout", "-q", "-b", "fix/x");
  git(dir, "config", "--local", "branch.fix/x.base", "main");
  writeFileSync(path.join(dir, "a.txt"), "two\n");
  writeFileSync(path.join(dir, "b.txt"), "new\n");
  git(dir, "add", "b.txt");
  git(dir, "commit", "-q", "-m", "add b");
  writeFileSync(path.join(dir, "c.txt"), "c\n");
  git(dir, "add", "c.txt");

  const result = await worktreeStatus(dir);
  assert.ok(result.ok, JSON.stringify(result));
  assert.equal(result.status.branch, "fix/x");
  assert.equal(result.status.base, "main");
  assert.equal(result.status.ahead, 1);
  assert.equal(result.status.behind, 0);
  assert.deepEqual(result.status.files.map((f) => [f.path, f.staged]).sort(), [
    ["a.txt", false],
    ["c.txt", true],
  ]);
  assert.equal(result.status.staged, 1);
});

test("stage, unstage, and commit exactly the staged set; refusals are sentences", async () => {
  const dir = repo();
  writeFileSync(path.join(dir, "a.txt"), "two\n");
  writeFileSync(path.join(dir, "b.txt"), "b\n");

  const nothing = await commitStaged(dir, "feat: nope");
  assert.equal(nothing.ok, false);
  if (!nothing.ok) assert.equal(nothing.status, 409);

  const empty = await commitStaged(dir, "   ");
  assert.equal(empty.ok, false);
  if (!empty.ok) assert.equal(empty.status, 400);

  const escape = await stageFiles(dir, ["../outside.txt"], "stage");
  assert.equal(escape.ok, false);

  assert.ok((await stageFiles(dir, ["a.txt", "b.txt"], "stage")).ok);
  assert.ok((await stageFiles(dir, ["b.txt"], "unstage")).ok);
  const before = await worktreeStatus(dir);
  assert.ok(before.ok);
  assert.equal(before.status.staged, 1);

  const committed = await commitStaged(dir, "fix: a only");
  assert.ok(committed.ok, JSON.stringify(committed));
  assert.equal(committed.commit.summary, "fix: a only");
  assert.equal(committed.commit.files, 1);
  assert.match(committed.commit.sha, /^[0-9a-f]{40}$/);

  const after = await worktreeStatus(dir);
  assert.ok(after.ok);
  assert.deepEqual(
    after.status.files.map((f) => f.path),
    ["b.txt"],
  );
  assert.equal(after.status.staged, 0);
});

test("stage all takes every changed file", async () => {
  const dir = repo();
  writeFileSync(path.join(dir, "a.txt"), "two\n");
  writeFileSync(path.join(dir, "new.txt"), "n\n");
  const result = await stageFiles(dir, "all", "stage");
  assert.ok(result.ok);
  assert.equal(result.staged, 2);
  const status = await worktreeStatus(dir);
  assert.ok(status.ok);
  assert.equal(status.status.staged, 2);
});

// A branch two commits over main while main moved on by one, with a bare
// "remote" beside it so push works without a network (#78).
function branched(): { dir: string; remote: string } {
  const dir = repo();
  const remote = path.join(path.dirname(dir), "remote.git");
  git(path.dirname(dir), "init", "-q", "--bare", "remote.git");
  git(dir, "remote", "add", "origin", remote);
  git(dir, "push", "-q", "origin", "main");
  git(dir, "checkout", "-q", "-b", "feat/x");
  git(dir, "config", "--local", "branch.feat/x.base", "main");
  writeFileSync(path.join(dir, "b.txt"), "b\n");
  git(dir, "add", "b.txt");
  git(dir, "commit", "-q", "-m", "feat: add b");
  writeFileSync(path.join(dir, "c.txt"), "c\n");
  git(dir, "add", "c.txt");
  git(dir, "commit", "-q", "-m", "feat: add c");
  git(dir, "checkout", "-q", "main");
  writeFileSync(path.join(dir, "m.txt"), "m\n");
  git(dir, "add", "m.txt");
  git(dir, "commit", "-q", "-m", "chore: main moved");
  git(dir, "checkout", "-q", "feat/x");
  return { dir, remote };
}

test("log lists the commits ahead of and behind the base, newest first, with the push remote and no upstream yet", async () => {
  const { dir } = branched();
  const result = await worktreeLog(dir);
  assert.ok(result.ok, JSON.stringify(result));
  assert.equal(result.log.branch, "feat/x");
  assert.equal(result.log.base, "main");
  assert.deepEqual(
    result.log.ahead.map((c) => c.summary),
    ["feat: add c", "feat: add b"],
  );
  assert.deepEqual(
    result.log.behind.map((c) => c.summary),
    ["chore: main moved"],
  );
  assert.equal(result.log.ahead[0]?.author, "t");
  assert.match(result.log.ahead[0]?.sha ?? "", /^[0-9a-f]{40}$/);
  assert.match(result.log.ahead[0]?.when ?? "", /^\d{4}-\d{2}-\d{2}T/);
  assert.equal(result.log.upstream, null);
  assert.equal(result.log.remote, "origin");
  assert.equal(result.log.truncated, false);
});

test("push sets the upstream the first time, then says when there is nothing more to push", async () => {
  const { dir, remote } = branched();
  const first = await pushBranch(dir);
  assert.ok(first.ok, JSON.stringify(first));
  assert.equal(first.pushed, 2);
  assert.equal(first.upstream, "origin/feat/x");
  assert.equal(git(dir, "rev-parse", "--abbrev-ref", "feat/x@{upstream}").trim(), "origin/feat/x");
  assert.equal(git(remote, "rev-parse", "refs/heads/feat/x").trim(), git(dir, "rev-parse", "HEAD").trim());

  const again = await pushBranch(dir);
  assert.equal(again.ok, false);
  if (!again.ok) {
    assert.equal(again.status, 409);
    assert.match(again.error, /already has everything/);
  }

  writeFileSync(path.join(dir, "d.txt"), "d\n");
  git(dir, "add", "d.txt");
  git(dir, "commit", "-q", "-m", "feat: add d");
  const log = await worktreeLog(dir);
  assert.ok(log.ok);
  assert.deepEqual(log.log.upstream, { name: "origin/feat/x", ahead: 1, behind: 0 });
  const second = await pushBranch(dir);
  assert.ok(second.ok, JSON.stringify(second));
  assert.equal(second.pushed, 1);
});

test("push refuses in words with no remote, and when the remote moved on", async () => {
  const lonely = repo();
  const none = await pushBranch(lonely);
  assert.equal(none.ok, false);
  if (!none.ok) {
    assert.equal(none.status, 409);
    assert.match(none.error, /no remote/);
  }

  const { dir, remote } = branched();
  assert.ok((await pushBranch(dir)).ok);
  // Someone else pushes to the same branch from another clone.
  const other = path.join(path.dirname(dir), "other");
  git(path.dirname(dir), "clone", "-q", remote, "other");
  git(other, "config", "user.name", "o");
  git(other, "config", "user.email", "o@o");
  git(other, "checkout", "-q", "feat/x");
  writeFileSync(path.join(other, "o.txt"), "o\n");
  git(other, "add", "o.txt");
  git(other, "commit", "-q", "-m", "feat: elsewhere");
  git(other, "push", "-q", "origin", "feat/x");
  writeFileSync(path.join(dir, "e.txt"), "e\n");
  git(dir, "add", "e.txt");
  git(dir, "commit", "-q", "-m", "feat: add e");
  const rejected = await pushBranch(dir);
  assert.equal(rejected.ok, false);
  if (!rejected.ok) {
    assert.equal(rejected.status, 409);
    assert.match(rejected.error, /has commits this branch does not/);
  }
});

test("pull-base fetches the base's upstream first: a commit pushed elsewhere comes in, and the local base moves up when nothing stands on it (#83)", async () => {
  const { dir, remote } = branched();
  // Someone else pushes to main from another clone.
  const other = path.join(path.dirname(dir), "other");
  git(path.dirname(dir), "clone", "-q", remote, "other");
  // The bare remote's HEAD names a branch nobody pushed; stand on main.
  git(other, "checkout", "-q", "main");
  writeFileSync(path.join(other, "remote.txt"), "from elsewhere\n");
  git(other, "add", "remote.txt");
  git(other, "commit", "-q", "-m", "chore: pushed elsewhere");
  git(other, "push", "-q", "origin", "main");
  // The local main tracks origin/main (as a clone's would) but has its own
  // commit too — diverged — so it is merged as it stands.
  git(dir, "branch", "--set-upstream-to=origin/main", "main");
  const diverged = await pullBase(dir);
  assert.ok(diverged.ok, JSON.stringify(diverged));
  assert.equal(diverged.fetched, true);
  assert.equal(diverged.from, "main");
  assert.equal(diverged.merged, 1);
  assert.equal(existsSync(path.join(dir, "remote.txt")), false);

  // Local main made the remote's (force-pushed, level); the remote moves again.
  git(dir, "push", "-q", "--force", "origin", "main");
  git(other, "fetch", "-q", "origin");
  git(other, "reset", "-q", "--hard", "origin/main");
  writeFileSync(path.join(other, "again.txt"), "again\n");
  git(other, "add", "again.txt");
  git(other, "commit", "-q", "-m", "chore: pushed again");
  git(other, "push", "-q", "origin", "main");
  // Nothing stands on main here (the checkout is on feat/x), so the fetch
  // fast-forwards local main and that is what gets merged.
  const behind = await pullBase(dir);
  assert.ok(behind.ok, JSON.stringify(behind));
  assert.equal(behind.fetched, true);
  assert.equal(behind.from, "main");
  assert.ok(behind.merged >= 1);
  assert.equal(existsSync(path.join(dir, "again.txt")), true);
  assert.equal(git(dir, "rev-parse", "main").trim(), git(dir, "rev-parse", "origin/main").trim());

  // With main checked out in a second worktree, `branch -f` is refused and
  // the fresh remote-tracking ref is merged instead.
  const mainCheckout = path.join(path.dirname(dir), "main-checkout");
  git(dir, "worktree", "add", "-q", mainCheckout, "main");
  writeFileSync(path.join(other, "third.txt"), "third\n");
  git(other, "add", "third.txt");
  git(other, "commit", "-q", "-m", "chore: third");
  git(other, "push", "-q", "origin", "main");
  const tracking = await pullBase(dir);
  assert.ok(tracking.ok, JSON.stringify(tracking));
  assert.equal(tracking.from, "origin/main");
  assert.equal(tracking.merged, 1);
  assert.equal(existsSync(path.join(dir, "third.txt")), true);
});

test("pull-base merges the base in, reports nothing to do when level, and aborts a conflict with the file named", async () => {
  const { dir } = branched();
  const merged = await pullBase(dir);
  assert.ok(merged.ok, JSON.stringify(merged));
  assert.equal(merged.merged, 1);
  assert.equal(merged.fastForward, false);
  // No upstream on main: nothing to fetch, and the answer says so.
  assert.equal(merged.fetched, false);
  assert.equal(merged.from, "main");
  assert.equal(git(dir, "rev-list", "--count", "feat/x..main").trim(), "0");
  assert.equal(git(dir, "status", "--porcelain").trim(), "");

  const level = await pullBase(dir);
  assert.ok(level.ok);
  assert.equal(level.merged, 0);

  // main and the branch now change the same line.
  git(dir, "checkout", "-q", "main");
  writeFileSync(path.join(dir, "a.txt"), "main says\n");
  git(dir, "commit", "-q", "-am", "main: a");
  git(dir, "checkout", "-q", "feat/x");
  writeFileSync(path.join(dir, "a.txt"), "branch says\n");
  git(dir, "commit", "-q", "-am", "branch: a");
  const head = git(dir, "rev-parse", "HEAD").trim();
  const conflict = await pullBase(dir);
  assert.equal(conflict.ok, false);
  if (!conflict.ok) {
    assert.equal(conflict.status, 409);
    assert.match(conflict.error, /conflicts with feat\/x in a\.txt/);
  }
  assert.equal(git(dir, "rev-parse", "HEAD").trim(), head);
  assert.equal(git(dir, "status", "--porcelain").trim(), "");

  // Uncommitted work that the merge would overwrite is refused, untouched.
  git(dir, "checkout", "-q", "main");
  writeFileSync(path.join(dir, "m.txt"), "m2\n");
  git(dir, "commit", "-q", "-am", "main: m2");
  git(dir, "checkout", "-q", "feat/x");
  writeFileSync(path.join(dir, "m.txt"), "local edit\n");
  const dirty = await pullBase(dir);
  assert.equal(dirty.ok, false);
  if (!dirty.ok) assert.match(dirty.error, /Uncommitted changes|conflicts/);
  assert.equal(git(dir, "status", "--porcelain").trimEnd(), " M m.txt");
});

test("commit message comes from the model with secrets left out of the diff, and says so when nothing is staged", async () => {
  const dir = repo();
  const nothing = await writeCommitMessage(dir, { shell: "/bin/sh", runClaude: async () => "x" });
  assert.equal(nothing.ok, false);
  if (!nothing.ok) assert.equal(nothing.status, 409);

  writeFileSync(path.join(dir, "a.txt"), "two\n");
  writeFileSync(path.join(dir, ".env"), "TOKEN=hunter2\n");
  git(dir, "add", "a.txt", ".env");
  let seen = "";
  const result = await writeCommitMessage(dir, {
    shell: "/bin/sh",
    runClaude: async (_prompt, input) => {
      seen = input;
      return "feat(a): count to two\n\nignored second line";
    },
  });
  assert.ok(result.ok, JSON.stringify(result));
  assert.equal(result.message, "feat(a): count to two");
  assert.match(seen, /Staged files: \.env, a\.txt/);
  assert.match(seen, /\+two/);
  assert.doesNotMatch(seen, /hunter2/);

  const missing = await writeCommitMessage(dir, {
    shell: "/bin/sh",
    runClaude: async () => {
      throw new Error("claude is not installed");
    },
  });
  assert.equal(missing.ok, false);
  if (!missing.ok) assert.match(missing.error, /not installed/);
});
