import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test, { type TestContext } from "node:test";
import { currentVersion, packageRootFor, readPending, runtimeLayout, switchCurrent } from "./runtime.js";
import { checkAndApply, markStarted, newerCompatible, startUpdater, type UpdaterDeps } from "./updater.js";

test("only a newer release in the same major counts as an update", () => {
  assert.equal(newerCompatible("0.1.6", "0.1.7"), true);
  assert.equal(newerCompatible("0.1.6", "0.2.0"), true);
  assert.equal(newerCompatible("0.1.6", "0.1.6"), false);
  assert.equal(newerCompatible("0.1.6", "0.1.5"), false);
  assert.equal(newerCompatible("0.1.6", "1.0.0"), false);
  assert.equal(newerCompatible("0.1.6", "0.1.7-beta.1"), false);
  assert.equal(newerCompatible("garbage", "0.1.7"), false);
});

test("an update installs beside the running version, marks it pending, switches, prunes, and restarts", async (context) => {
  const { layout, deps, calls } = fixture(context, { current: "0.1.6", latest: "0.1.7" });
  mkdirSync(packageRootFor(layout, "0.1.4"), { recursive: true });

  const outcome = await checkAndApply(deps);

  assert.deepEqual(outcome, { status: "updated", from: "0.1.6", to: "0.1.7" });
  assert.deepEqual(calls, [`install 0.1.7 ${path.join(layout.versionsDir, "0.1.7")}`, "verify 0.1.7", "restart"]);
  assert.equal(currentVersion(layout), "0.1.7");
  assert.deepEqual(readPending(layout)?.version, "0.1.7");
  assert.equal(readPending(layout)?.previous, "0.1.6");
  assert.equal(readPending(layout)?.attempts, 0);
  assert.equal(existsSync(packageRootFor(layout, "0.1.4")), false, "older versions are pruned");
  assert.equal(existsSync(packageRootFor(layout, "0.1.6")), true, "the previous version stays for rollback");
});

test("nothing newer: no install, no restart", async (context) => {
  const { deps, calls } = fixture(context, { current: "0.1.6", latest: "0.1.6" });
  assert.deepEqual(await checkAndApply(deps), { status: "current", version: "0.1.6" });
  assert.deepEqual(calls, []);
});

test("a download that reports the wrong version is never switched to", async (context) => {
  const { layout, deps, calls } = fixture(context, { current: "0.1.6", latest: "0.1.7", verifyReports: "0.1.6" });
  const outcome = await checkAndApply(deps);
  assert.equal(outcome.status, "failed");
  assert.match((outcome as { reason: string }).reason, /reports version 0\.1\.6, expected 0\.1\.7/);
  assert.equal(currentVersion(layout), "0.1.6");
  assert.equal(readPending(layout), undefined);
  assert.ok(!calls.includes("restart"));
});

test("npm unreachable is reported, not fatal", async (context) => {
  const { deps } = fixture(context, { current: "0.1.6", latest: undefined });
  assert.deepEqual(await checkAndApply(deps), { status: "failed", reason: "could not reach npm to check for updates" });
});

test("a host that starts cleanly clears the pending marker for its own version only", async (context) => {
  const { layout, deps } = fixture(context, { current: "0.1.6", latest: "0.1.7" });
  await checkAndApply(deps);
  assert.equal(markStarted(layout, "0.1.6"), false);
  assert.equal(readPending(layout)?.version, "0.1.7");
  assert.equal(markStarted(layout, "0.1.7"), true);
  assert.equal(readPending(layout), undefined);
});

test("the schedule checks after the initial delay, then daily, and never overlaps", async (context) => {
  const { deps, calls } = fixture(context, { current: "0.1.6", latest: "0.1.6" });
  const timers: Array<{ fn: () => void; ms: number }> = [];
  let checks = 0;
  deps.fetchLatest = async () => {
    checks += 1;
    return "0.1.6";
  };
  const updater = startUpdater(deps, { initialDelayMs: 1000, intervalMs: 10_000, setTimer: (fn, ms) => (timers.push({ fn, ms }), {}) });
  assert.equal(timers[0]?.ms, 1000);
  timers[0]?.fn();
  const [a, b] = [updater.checkNow(), updater.checkNow()];
  await Promise.all([a, b]);
  assert.equal(checks, 1, "overlapping calls share one check");
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.ok(timers[1] && timers[1].ms >= 9000 && timers[1].ms <= 11000, "daily with jitter");
  assert.deepEqual(calls, []);
});

function fixture(context: TestContext, input: { current: string; latest: string | undefined; verifyReports?: string }) {
  const stateDir = mkdtempSync(path.join(tmpdir(), "tavi-updater-"));
  context.after(() => rmSync(stateDir, { recursive: true, force: true }));
  const layout = runtimeLayout(stateDir);
  mkdirSync(path.join(packageRootFor(layout, input.current), "dist"), { recursive: true });
  switchCurrent(layout, input.current);
  const calls: string[] = [];
  const deps: UpdaterDeps = {
    currentVersion: input.current,
    layout,
    log: () => {},
    fetchLatest: async () => input.latest,
    install: async (version, prefix) => {
      calls.push(`install ${version} ${prefix}`);
      mkdirSync(path.join(prefix, "node_modules", "tavi-host", "dist"), { recursive: true });
      writeFileSync(path.join(prefix, "node_modules", "tavi-host", "dist", "index.js"), "", "utf8");
    },
    verify: async (packageRoot) => {
      calls.push(`verify ${path.basename(path.dirname(path.dirname(packageRoot)))}`);
      return input.verifyReports ?? input.latest ?? "";
    },
    restart: () => calls.push("restart"),
  };
  return { layout, deps, calls };
}
