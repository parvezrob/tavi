import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { diffFile, listChanges, parsePorcelain } from "./changes.js";

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

function repo(): string {
  const dir = mkdtempSync(path.join(tmpdir(), "tavi-changes-"));
  git(dir, "init", "-q", "-b", "main");
  mkdirSync(path.join(dir, "src"));
  writeFileSync(path.join(dir, "src", "a.ts"), "one\ntwo\nthree\n");
  writeFileSync(path.join(dir, "keep.md"), "# keep\n");
  writeFileSync(path.join(dir, "old.txt"), "old\n");
  git(dir, "add", ".");
  git(dir, "commit", "-q", "-m", "init");
  return dir;
}

test("lists modified, added, deleted, renamed, and untracked files with counts", async () => {
  const dir = repo();
  writeFileSync(path.join(dir, "src", "a.ts"), "one\n2\nthree\nfour\n");
  writeFileSync(path.join(dir, "new.ts"), "new\n");
  git(dir, "add", "new.ts");
  unlinkSync(path.join(dir, "keep.md"));
  renameSync(path.join(dir, "old.txt"), path.join(dir, "renamed.txt"));
  git(dir, "add", "-A", "old.txt", "renamed.txt");
  writeFileSync(path.join(dir, "notes.txt"), "scratch\n");
  writeFileSync(path.join(dir, ".env"), "SECRET=1\n");

  const result = await listChanges(path.join(dir, "src"));
  assert.ok(result.ok);
  assert.equal(result.branch, "main");
  const byPath = new Map(result.files.map((file) => [file.path, file]));
  assert.equal(byPath.get("src/a.ts")?.state, "modified");
  assert.equal(byPath.get("src/a.ts")?.unstaged, true);
  assert.deepEqual([byPath.get("src/a.ts")?.additions, byPath.get("src/a.ts")?.deletions], [2, 1]);
  assert.equal(byPath.get("new.ts")?.state, "added");
  assert.equal(byPath.get("new.ts")?.staged, true);
  assert.equal(byPath.get("keep.md")?.state, "deleted");
  assert.equal(byPath.get("renamed.txt")?.state, "renamed");
  assert.equal(byPath.get("renamed.txt")?.from, "old.txt");
  assert.equal(byPath.get("notes.txt")?.state, "untracked");
  assert.equal(byPath.get(".env")?.secret, true);
  assert.equal(result.truncated, false);
});

test("a folder that is not a repository says so", async () => {
  const dir = mkdtempSync(path.join(tmpdir(), "tavi-norepo-"));
  const result = await listChanges(dir);
  assert.equal(result.ok, false);
  assert.equal((result as { notRepository?: true }).notRepository, true);
  assert.equal((result as { status: number }).status, 404);
});

test("one file's diff covers tracked changes and untracked files; secrets are refused", async () => {
  const dir = repo();
  writeFileSync(path.join(dir, "src", "a.ts"), "one\n2\nthree\n");
  const tracked = await diffFile(dir, "src/a.ts");
  assert.ok(tracked.ok);
  assert.match(tracked.diff.diff, /^-two$/m);
  assert.match(tracked.diff.diff, /^\+2$/m);
  assert.equal(tracked.diff.binary, false);

  writeFileSync(path.join(dir, "fresh.txt"), "brand new\n");
  const untracked = await diffFile(dir, "fresh.txt");
  assert.ok(untracked.ok);
  assert.match(untracked.diff.diff, /^\+brand new$/m);

  writeFileSync(path.join(dir, ".env"), "SECRET=1\n");
  const secret = await diffFile(dir, ".env");
  assert.equal(secret.ok, false);
  assert.equal((secret as { status: number }).status, 403);

  const escaped = await diffFile(dir, "../etc/passwd");
  assert.equal((escaped as { status: number }).status, 400);
  const absolute = await diffFile(dir, "/etc/passwd");
  assert.equal((absolute as { status: number }).status, 400);
});

test("a binary change is flagged, not dumped", async () => {
  const dir = repo();
  writeFileSync(path.join(dir, "img.png"), Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x00, 0x01]));
  git(dir, "add", "img.png");
  git(dir, "commit", "-q", "-m", "img");
  writeFileSync(path.join(dir, "img.png"), Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x00, 0x02, 0x03]));
  const result = await diffFile(dir, "img.png");
  assert.ok(result.ok);
  assert.equal(result.diff.binary, true);
});

test("porcelain parsing handles renames and conflicts", () => {
  const files = parsePorcelain("R  new.txt\0old.txt\0UU clash.ts\0?? loose\0 M a\0");
  assert.deepEqual(
    files.map((file) => [file.path, file.state, file.from ?? null, file.staged, file.unstaged]),
    [
      ["new.txt", "renamed", "old.txt", true, false],
      ["clash.ts", "conflict", null, true, true],
      ["loose", "untracked", null, false, true],
      ["a", "modified", null, false, true],
    ],
  );
});
