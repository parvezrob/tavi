import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  statSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { MAX_UPLOAD_BYTES, extensionFor, saveUpload } from "./uploads.js";

function repo(): { root: string; project: string } {
  const root = realpathSync(mkdtempSync(path.join(tmpdir(), "tavi-uploads-")));
  const project = path.join(root, "app");
  mkdirSync(project);
  execFileSync("git", ["init", "-q", project]);
  return { root, project };
}

test("saveUpload writes the image under .tavi/uploads, keeps it out of git, and answers the path", async () => {
  const { root, project } = repo();
  const saved = await saveUpload({
    cwd: project,
    roots: [root],
    contentType: "image/png",
    body: Buffer.from("png-bytes"),
  });
  assert.equal(saved.ok, true);
  if (!saved.ok) return;
  assert.ok(saved.path.startsWith(path.join(project, ".tavi", "uploads", "")));
  assert.ok(saved.path.endsWith(".png"));
  assert.equal(readFileSync(saved.path, "utf8"), "png-bytes");
  assert.equal(saved.bytes, 9);
  assert.match(readFileSync(path.join(project, ".git", "info", "exclude"), "utf8"), /^\.tavi\/uploads\/$/m);
  // The exclude line is written once.
  await saveUpload({ cwd: project, roots: [root], contentType: "image/jpeg", body: Buffer.from("jpg") });
  const lines = readFileSync(path.join(project, ".git", "info", "exclude"), "utf8")
    .split("\n")
    .filter((line) => line === ".tavi/uploads/");
  assert.equal(lines.length, 1);
  // git sees nothing to commit.
  const status = execFileSync("git", ["-C", project, "status", "--porcelain"], { encoding: "utf8" });
  assert.equal(status.trim(), "");
});

test("saveUpload refuses what it must: outside the roots, not an image, empty, too large, a file for a cwd", async () => {
  const { root, project } = repo();
  const outside = realpathSync(mkdtempSync(path.join(tmpdir(), "tavi-outside-")));
  const refused = await saveUpload({ cwd: outside, roots: [root], contentType: "image/png", body: Buffer.from("x") });
  assert.deepEqual(refused, {
    ok: false,
    status: 403,
    error: "That file is outside your project folders.",
    outsideRoots: true,
  });
  assert.equal(
    (await saveUpload({ cwd: project, roots: [root], contentType: "text/plain", body: Buffer.from("x") })).ok,
    false,
  );
  assert.equal(
    (await saveUpload({ cwd: project, roots: [root], contentType: "application/octet-stream", body: Buffer.from("x") }))
      .ok,
    false,
  );
  assert.equal(
    (await saveUpload({ cwd: project, roots: [root], contentType: "image/png", body: Buffer.alloc(0) })).ok,
    false,
  );
  const big = await saveUpload({
    cwd: project,
    roots: [root],
    contentType: "image/png",
    body: Buffer.alloc(MAX_UPLOAD_BYTES + 1),
  });
  assert.equal(big.ok, false);
  if (!big.ok) assert.equal(big.status, 413);
  writeFileSync(path.join(project, "notes.txt"), "hi");
  const notAFolder = await saveUpload({
    cwd: path.join(project, "notes.txt"),
    roots: [root],
    contentType: "image/png",
    body: Buffer.from("x"),
  });
  assert.equal(notAFolder.ok, false);
  assert.equal(extensionFor("image/jpeg; charset=binary"), "jpg");
  assert.equal(extensionFor("image/svg+xml"), null);
  assert.equal(extensionFor(undefined), null);
});

test("saveUpload sweeps images older than a week and never the one just written", async () => {
  const { root, project } = repo();
  const first = await saveUpload({ cwd: project, roots: [root], contentType: "image/png", body: Buffer.from("old") });
  assert.equal(first.ok, true);
  if (!first.ok) return;
  const eightDaysAgo = new Date(Date.now() - 8 * 24 * 60 * 60 * 1000);
  utimesSync(first.path, eightDaysAgo, eightDaysAgo);
  const second = await saveUpload({ cwd: project, roots: [root], contentType: "image/png", body: Buffer.from("new") });
  assert.equal(second.ok, true);
  if (!second.ok) return;
  assert.equal(existsSync(first.path), false);
  assert.ok(statSync(second.path).isFile());
});
