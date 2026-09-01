// npm drops the execute bit on node-pty's prebuilt spawn-helper in some
// install paths; without it every pty spawn fails with EACCES. Resolve the
// package wherever npm hoisted it (a checkout, `npm i -g`, the npx cache,
// ~/.tavi/runtime) rather than assuming a node_modules next to us.
import { chmodSync, existsSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

if (process.platform !== "win32") {
  try {
    const packageJson = createRequire(import.meta.url).resolve("node-pty/package.json");
    const helper = path.join(
      path.dirname(packageJson),
      "prebuilds",
      `${process.platform}-${process.arch}`,
      "spawn-helper",
    );
    if (existsSync(helper)) chmodSync(helper, 0o755);
  } catch {
    // node-pty not installed yet (e.g. a partial install); nothing to fix.
  }
}
