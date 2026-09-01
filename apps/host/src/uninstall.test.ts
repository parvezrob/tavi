import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test, { type TestContext } from "node:test";
import { installClaudeHooks, removeClaudeHooks } from "./claude-hooks.js";
import type { HostConfig } from "./config.js";
import { uninstall, type UninstallDeps } from "./uninstall.js";

function config(stateDir: string): HostConfig {
  return { bindHost: "127.0.0.1", port: 8787, token: "token-long-enough-for-the-test-suite", shell: "/bin/sh", herdrSocket: "/tmp/h.sock", roots: [], stateDir, machineName: "m", previewPort: 8788, previewDoorPort: 8443 };
}

function deps(overrides: Partial<UninstallDeps> & { answer: boolean; handlers?: Array<[string, string]> }) {
  const calls: string[] = [];
  const reports: string[] = [];
  const d: UninstallDeps = {
    ask: async () => overrides.answer,
    report: (m) => reports.push(m),
    uninstallService: async () => { calls.push("service"); },
    uninstallHerdrService: async () => { calls.push("herdr"); },
    removeClaudeHooks: () => { calls.push("hooks"); return true; },
    serveHandlers: async () => overrides.handlers ?? [["mac.ts.net:443", "http://127.0.0.1:8787"]],
    resetServe: async () => { calls.push("serve-reset"); },
    removeCommandLink: () => { calls.push("command-link"); return "/usr/local/bin/tavi"; },
    ...overrides,
  };
  return { d, calls, reports };
}

test("uninstall removes the host, Tavi's herdr service, hooks, the Serve entry, and ~/.tavi after one yes", async (context) => {
  const home = temp(context);
  const stateDir = path.join(home, ".tavi");
  mkdirSync(stateDir, { recursive: true });
  writeFileSync(path.join(stateDir, "devices.json"), "{}", "utf8");
  const { d, calls, reports } = deps({ answer: true });

  assert.equal(await uninstall(config(stateDir), d), true);

  assert.deepEqual(calls, ["service", "herdr", "command-link", "hooks", "serve-reset"]);
  assert.equal(existsSync(stateDir), false);
  assert.ok(reports.some((line) => /Tavi is gone from this computer/.test(line)));
  assert.ok(reports.some((line) => /Still installed.*Tailscale.*herdr.*Node/.test(line)));
});

test("uninstall leaves a shared Tailscale Serve config alone and says so", async (context) => {
  const home = temp(context);
  const { d, calls, reports } = deps({ answer: true, handlers: [["mac.ts.net:443", "http://127.0.0.1:8787"], ["mac.ts.net:443", "http://127.0.0.1:3000"]] });
  await uninstall(config(path.join(home, ".tavi")), d);
  assert.ok(!calls.includes("serve-reset"));
  assert.ok(reports.some((line) => /left alone.*something else of yours/.test(line)), reports.join("\n"));
});

test("saying no changes nothing", async (context) => {
  const home = temp(context);
  const stateDir = path.join(home, ".tavi");
  mkdirSync(stateDir, { recursive: true });
  const { d, calls } = deps({ answer: false });
  assert.equal(await uninstall(config(stateDir), d), false);
  assert.deepEqual(calls, []);
  assert.equal(existsSync(stateDir), true);
});

test("removeClaudeHooks takes out only Tavi's entries", (context) => {
  const home = temp(context);
  const settings = path.join(home, "settings.json");
  writeFileSync(settings, JSON.stringify({ hooks: { Stop: [{ hooks: [{ type: "command", command: "say done" }] }] }, theme: "dark" }), "utf8");
  installClaudeHooks(config(home), settings);
  assert.equal(removeClaudeHooks(settings), true);
  const after = JSON.parse(readFileSync(settings, "utf8")) as { hooks: Record<string, unknown[]>; theme: string };
  assert.deepEqual(Object.keys(after.hooks), ["Stop"]);
  assert.equal(after.hooks.Stop?.length, 1);
  assert.equal(after.theme, "dark");
  assert.equal(removeClaudeHooks(settings), false);
});

function temp(context: TestContext): string {
  const dir = mkdtempSync(path.join(tmpdir(), "tavi-uninstall-"));
  context.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}
