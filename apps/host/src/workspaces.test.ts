import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { scanWorkspaces } from "./workspaces.js";

test("lists each root and its visible subfolders, git repositories first", async (context) => {
  const root = mkdtempSync(path.join(tmpdir(), "host-workspaces-"));
  context.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(path.join(root, "notes"));
  mkdirSync(path.join(root, "api", ".git"), { recursive: true });
  mkdirSync(path.join(root, ".hidden"));
  writeFileSync(path.join(root, "README.md"), "not a folder\n");

  const workspaces = await scanWorkspaces([root, path.join(root, "does-not-exist")]);

  assert.deepEqual(workspaces, [
    { name: "api", path: path.join(root, "api"), git: true },
    { name: path.basename(root), path: root, git: false },
    { name: "notes", path: path.join(root, "notes"), git: false },
  ]);
});

test("an unreadable or missing root yields nothing rather than an error", async () => {
  assert.deepEqual(await scanWorkspaces(["/definitely/not/here"]), []);
});
