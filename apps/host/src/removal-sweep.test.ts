import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
  describeSweep,
  isRemovalLeftover,
  leftoverName,
  listRemovalLeftovers,
  sweepRemovalLeftovers,
} from "./removal-sweep.js";
import { scanWorkspaces } from "./workspaces.js";

function root(): string {
  return realpathSync(mkdtempSync(path.join(tmpdir(), "tavi-sweep-")));
}

test("a leftover is named the way removal names it, and nothing else looks like one", () => {
  const aside = leftoverName("/Users/me/Projects/app-worktrees/fix-foo");
  assert.ok(isRemovalLeftover(path.basename(aside)), aside);
  assert.match(aside, /^\/Users\/me\/Projects\/app-worktrees\/fix-foo\.removing-[0-9a-z]+$/);
  assert.equal(isRemovalLeftover("fix-foo"), false);
  assert.equal(isRemovalLeftover("removing-notes"), false);
  assert.equal(isRemovalLeftover("app.removing-"), false);
});

test("the sweep deletes leftovers beside a repository and inside its worktrees folder, touches nothing else, and the picker never lists them (#82)", async () => {
  const base = root();
  const beside = path.join(base, "app-fix.removing-abc12");
  const inside = path.join(base, "app-worktrees", "fix-foo.removing-zz9");
  const keep = path.join(base, "app-worktrees", "fix-bar");
  const deeper = path.join(base, "unrelated", "x.removing-abc");
  for (const folder of [beside, inside, keep, deeper, path.join(base, "app", ".git")])
    mkdirSync(folder, { recursive: true });
  writeFileSync(path.join(beside, "file.txt"), "leftover\n");

  assert.deepEqual(await listRemovalLeftovers([base, "/definitely/not/here"]), [inside, beside].sort());
  // The picker's root scan skips a leftover before the sweep gets to it.
  const listed = (await scanWorkspaces([base])).map((workspace) => workspace.name);
  assert.equal(listed.includes(path.basename(beside)), false);
  assert.ok(listed.includes("app"));

  const report = await sweepRemovalLeftovers([base]);
  assert.deepEqual(report, { removed: [inside, beside].sort(), stranded: [] });
  assert.equal(existsSync(beside), false);
  assert.equal(existsSync(inside), false);
  assert.equal(existsSync(keep), true);
  // Two levels under a root that is not a worktrees folder is not swept.
  assert.equal(existsSync(deeper), true);
  assert.deepEqual(describeSweep(report), [
    `tavi: deleted 2 folders left by removed worktrees: ${[inside, beside].sort().join(", ")}`,
  ]);
  assert.deepEqual(describeSweep({ removed: [], stranded: [] }), []);
  assert.deepEqual(describeSweep({ removed: [], stranded: [{ path: beside, error: "EPERM" }] }), [
    `tavi: could not delete ${beside} (left by a removed worktree): EPERM`,
  ]);
});
