import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { defaultDeps } from "./bootstrap-deps.js";
import { testConfig } from "./testing/config.js";

// A stand-in login shell: `resolveOnLoginPath` runs `$SHELL -lc "command -v
// <name>"`, so the script answers on $2 and exits non-zero for anything it
// does not know — exactly how a real shell says "not installed".
function fakeShell(known: Record<string, string>): string {
  const file = path.join(mkdtempSync(path.join(tmpdir(), "tavi-shell-")), "shell");
  const cases = Object.entries(known)
    .map(([name, resolved]) => `    *"command -v ${name}") echo "${resolved}"; exit 0;;`)
    .join("\n");
  writeFileSync(file, `#!/bin/sh\ncase "$2" in\n${cases}\n    *) exit 1;;\nesac\n`, { mode: 0o700 });
  chmodSync(file, 0o700);
  return file;
}

test("which and the tavi command are resolved on the login shell's PATH, not the service's (#103)", async (t) => {
  const shell = fakeShell({ herdr: "/opt/version-manager/bin/herdr", tavi: "/opt/homebrew/bin/tavi" });
  const deps = defaultDeps(testConfig({ shell }));

  assert.equal(await deps.which("herdr"), "/opt/version-manager/bin/herdr");
  // A command the login shell cannot find is undefined, not a thrown error.
  assert.equal(await deps.which("gemini"), undefined);

  // Only an npx-style install needs a `tavi` shim, so say this run is one;
  // otherwise the check answers "not needed" without looking anything up.
  const previous = process.env.npm_command;
  process.env.npm_command = "exec";
  t.after(() => {
    if (previous === undefined) delete process.env.npm_command;
    else process.env.npm_command = previous;
  });
  const status = await defaultDeps(testConfig({ shell })).commandStatus();
  assert.equal(status.needed, true);
  assert.equal(status.ok, true);
  assert.match(status.detail, /\/opt\/homebrew\/bin\/tavi/);
});
