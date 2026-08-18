import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test, { type TestContext } from "node:test";
import { ConfigurationError, loadConfig } from "./config.js";

const LEGACY_TOKEN = "legacy-token-that-is-long-enough-to-preserve";

test("atomically migrates the legacy pairing token without deleting its rollback source", (context) => {
  const homeDirectory = temporaryHome(context);
  const legacyConfig = path.join(homeDirectory, ".agent-deck", "config.json");
  writeConfig(legacyConfig, LEGACY_TOKEN);

  const config = loadTestConfig(homeDirectory);
  const mochaConfig = path.join(homeDirectory, ".mocha", "config.json");

  assert.equal(config.token, LEGACY_TOKEN);
  assert.equal(JSON.parse(readFileSync(mochaConfig, "utf8")).token, LEGACY_TOKEN);
  assert.equal(JSON.parse(readFileSync(legacyConfig, "utf8")).token, LEGACY_TOKEN);
  assert.equal(statSync(mochaConfig).mode & 0o777, 0o600);
  assert.equal(loadTestConfig(homeDirectory).token, LEGACY_TOKEN);
});

test("rejects conflicting current and legacy credentials", (context) => {
  const homeDirectory = temporaryHome(context);
  writeConfig(path.join(homeDirectory, ".agent-deck", "config.json"), LEGACY_TOKEN);
  writeConfig(path.join(homeDirectory, ".mocha", "config.json"), "different-token-that-is-also-long-enough");

  assert.throws(() => loadTestConfig(homeDirectory), ConfigurationError);
});

test("rejects an invalid legacy configuration instead of rotating shell access", (context) => {
  const homeDirectory = temporaryHome(context);
  const legacyDirectory = path.join(homeDirectory, ".agent-deck");
  mkdirSync(legacyDirectory, { recursive: true });
  writeFileSync(path.join(legacyDirectory, "config.json"), "not-json\n", "utf8");

  assert.throws(() => loadTestConfig(homeDirectory), /cannot be migrated/);
  assert.equal(statExists(path.join(homeDirectory, ".mocha", "config.json")), false);
});

test("rejects legacy environment variables with an actionable migration error", (context) => {
  const homeDirectory = temporaryHome(context);

  assert.throws(
    () => loadTestConfig(homeDirectory, { DECK_PORT: "9999" }),
    /Rename them to MOCHA_\*/,
  );
});

test("uses only explicit Mocha environment configuration", (context) => {
  const homeDirectory = temporaryHome(context);
  const config = loadTestConfig(homeDirectory, {
    MOCHA_HOST: "localhost",
    MOCHA_MACHINE_NAME: "Studio",
    MOCHA_PORT: "9000",
    MOCHA_ROOTS: "/tmp",
    MOCHA_TOKEN: "explicit-token-that-is-long-enough",
  });

  assert.equal(config.bindHost, "localhost");
  assert.equal(config.machineName, "Studio");
  assert.equal(config.port, 9000);
  assert.deepEqual(config.roots, ["/tmp"]);
  assert.equal(config.token, "explicit-token-that-is-long-enough");
});

function loadTestConfig(homeDirectory: string, env: NodeJS.ProcessEnv = {}) {
  return loadConfig({
    env: { SHELL: "/bin/zsh", ...env },
    homeDirectory,
    machineHostname: "studio.local",
    operatingSystem: "darwin",
  });
}

function temporaryHome(context: TestContext): string {
  const directory = mkdtempSync(path.join(tmpdir(), "mocha-config-test-"));
  context.after(() => rmSync(directory, { recursive: true, force: true }));
  return directory;
}

function writeConfig(file: string, token: string): void {
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, `${JSON.stringify({ token }, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
}

function statExists(file: string): boolean {
  try {
    statSync(file);
    return true;
  } catch {
    return false;
  }
}
