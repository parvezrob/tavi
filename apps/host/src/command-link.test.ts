import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
  chooseBinDir,
  commandLinkSource,
  commandLinkStatus,
  isOurCommandLink,
  removeCommandLink,
  writeCommandLink,
} from "./command-link.js";
import { runtimeLayout } from "./runtime.js";

function home(): string {
  return mkdtempSync(path.join(tmpdir(), "tavi-home-"));
}

test("falls back to ~/.local/bin and knows whether it is on PATH", () => {
  const h = home();
  const off = chooseBinDir({ PATH: "/usr/bin:/bin" }, h);
  assert.equal(off.binDir, path.join(h, ".local", "bin"));
  assert.equal(off.onPath, false);
  const on = chooseBinDir({ PATH: `/usr/bin:${path.join(h, ".local", "bin")}` }, h);
  assert.equal(on.onPath, true);
});

test("the shim execs the runtime's current version through env node, marked as ours, executable", () => {
  const h = home();
  const layout = runtimeLayout(path.join(h, ".tavi"));
  const plan = chooseBinDir({ PATH: "/usr/bin" }, h);
  const written = writeCommandLink(plan, layout);
  assert.equal(written, path.join(h, ".local", "bin", "tavi"));
  const source = readFileSync(written, "utf8");
  assert.ok(source.startsWith("#!/bin/sh\n"));
  assert.match(source, /exec \/usr\/bin\/env node ".*\/runtime\/current\/node_modules\/tavi-host\/dist\/index\.js" "\$@"/);
  assert.equal(source, commandLinkSource(layout));
  assert.ok(statSync(written).mode & 0o111, "not executable");
  assert.ok(isOurCommandLink(written));
});

test("status: not needed for a checkout; ok when `which` finds it; says the PATH fix when installed but unreachable", () => {
  const h = home();
  assert.deepEqual(commandLinkStatus({ needed: false, env: {}, homeDir: h, resolved: undefined }), {
    needed: false,
    ok: true,
    detail: "not needed for this install",
  });
  assert.equal(commandLinkStatus({ needed: true, env: {}, homeDir: h, resolved: "/opt/homebrew/bin/tavi" }).ok, true);

  const missing = commandLinkStatus({ needed: true, env: {}, homeDir: h, resolved: undefined });
  assert.equal(missing.ok, false);
  assert.match(missing.fix ?? "", /npx tavi-host pair/);

  writeCommandLink(chooseBinDir({ PATH: "/usr/bin" }, h), runtimeLayout(path.join(h, ".tavi")));
  const unreachable = commandLinkStatus({ needed: true, env: {}, homeDir: h, resolved: undefined });
  assert.equal(unreachable.ok, false);
  assert.match(unreachable.detail, /not on your PATH/);
  assert.match(unreachable.fix ?? "", /\.local\/bin/);
});

test("removal takes only our shim and leaves a stranger's `tavi` alone", () => {
  const h = home();
  const layout = runtimeLayout(path.join(h, ".tavi"));
  writeCommandLink(chooseBinDir({ PATH: "/usr/bin" }, h), layout);
  const ours = path.join(h, ".local", "bin", "tavi");
  assert.ok(existsSync(ours));
  assert.equal(removeCommandLink(h), ours);
  assert.ok(!existsSync(ours));

  mkdirSync(path.dirname(ours), { recursive: true });
  writeFileSync(ours, "#!/bin/sh\necho someone else's tavi\n");
  chmodSync(ours, 0o755);
  assert.equal(removeCommandLink(h), undefined);
  assert.ok(existsSync(ours));
});
