import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test, { type TestContext } from "node:test";
import { promisify } from "node:util";
import { currentVersion, isManagedRuntime, packageRootFor, pruneVersions, readPending, runtimeLayout, switchCurrent, writeLauncher, writePending } from "./runtime.js";

const execFileAsync = promisify(execFile);

test("the launcher runs the current version, and rolls back after three failed starts of a fresh update", async (context) => {
  const stateDir = mkdtempSync(path.join(tmpdir(), "tavi-runtime-"));
  context.after(() => rmSync(stateDir, { recursive: true, force: true }));
  const layout = runtimeLayout(stateDir);
  const marker = path.join(stateDir, "ran.txt");

  fakeVersion(layout, "0.0.1", `import { writeFileSync } from "node:fs"; writeFileSync(process.env.MARK, "0.0.1");`);
  fakeVersion(layout, "0.0.2", `process.exit(1);`);
  writeLauncher(layout);

  // Healthy state: current = 0.0.1, nothing pending.
  switchCurrent(layout, "0.0.1");
  await run(layout, marker);
  assert.equal(readFileSync(marker, "utf8"), "0.0.1");

  // The updater switched to 0.0.2, which cannot start.
  writePending(layout, { version: "0.0.2", previous: "0.0.1", attempts: 0, startedAt: "now" });
  switchCurrent(layout, "0.0.2");
  rmSync(marker);
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    const result = await run(layout, marker);
    assert.equal(result.code, 1, `attempt ${attempt} should still try 0.0.2`);
    assert.equal(readPending(layout)?.attempts, attempt);
    assert.equal(currentVersion(layout), "0.0.2");
  }

  // Fourth start: rollback, then the previous version runs.
  const rolledBack = await run(layout, marker);
  assert.equal(rolledBack.code, 0);
  assert.match(rolledBack.stderr, /0\.0\.2 failed to start 3 times; rolled back to 0\.0\.1/);
  assert.equal(currentVersion(layout), "0.0.1");
  assert.equal(readPending(layout), undefined);
  assert.equal(readFileSync(marker, "utf8"), "0.0.1");
});

test("managed-runtime detection and pruning", (context) => {
  const stateDir = mkdtempSync(path.join(tmpdir(), "tavi-runtime-"));
  context.after(() => rmSync(stateDir, { recursive: true, force: true }));
  const layout = runtimeLayout(stateDir);
  assert.equal(isManagedRuntime(packageRootFor(layout, "0.1.6"), stateDir), true);
  assert.equal(isManagedRuntime(path.join(layout.currentLink, "node_modules", "tavi-host"), stateDir), true);
  assert.equal(isManagedRuntime("/Users/dev/tavi/apps/host", stateDir), false);
  assert.equal(isManagedRuntime("/opt/homebrew/lib/node_modules/tavi-host", stateDir), false);

  for (const version of ["0.1.4", "0.1.5", "0.1.6"]) mkdirSync(packageRootFor(layout, version), { recursive: true });
  assert.deepEqual(pruneVersions(layout, ["0.1.6", "0.1.5"]), ["0.1.4"]);
  assert.equal(existsSync(packageRootFor(layout, "0.1.5")), true);
});

function fakeVersion(layout: ReturnType<typeof runtimeLayout>, version: string, body: string): void {
  const root = packageRootFor(layout, version);
  mkdirSync(path.join(root, "dist"), { recursive: true });
  writeFileSync(path.join(root, "package.json"), JSON.stringify({ name: "tavi-host", version, type: "module" }));
  writeFileSync(path.join(root, "dist", "index.js"), `${body}\n`);
}

async function run(layout: ReturnType<typeof runtimeLayout>, marker: string): Promise<{ code: number; stderr: string }> {
  try {
    const { stderr } = await execFileAsync(process.execPath, [layout.launcher], { env: { ...process.env, MARK: marker } });
    return { code: 0, stderr };
  } catch (error) {
    const failure = error as { code?: number; stderr?: string };
    return { code: typeof failure.code === "number" ? failure.code : 1, stderr: failure.stderr ?? "" };
  }
}
