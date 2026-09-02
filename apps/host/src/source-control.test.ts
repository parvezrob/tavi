import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { commitStaged, stageFiles, worktreeStatus, writeCommitMessage } from "./source-control.js";

const identity = { GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" };

function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8", env: { ...process.env, ...identity } });
}

function repo(): string {
  const parent = realpathSync(mkdtempSync(path.join(tmpdir(), "tavi-sc-")));
  const dir = path.join(parent, "repo");
  git(parent, "init", "-q", "-b", "main", "repo");
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
  assert.deepEqual(result.status.files.map((f) => [f.path, f.staged]).sort(), [["a.txt", false], ["c.txt", true]]);
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
  assert.deepEqual(after.status.files.map((f) => f.path), ["b.txt"]);
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

  const missing = await writeCommitMessage(dir, { shell: "/bin/sh", runClaude: async () => { throw new Error("claude is not installed"); } });
  assert.equal(missing.ok, false);
  if (!missing.ok) assert.match(missing.error, /not installed/);
});
