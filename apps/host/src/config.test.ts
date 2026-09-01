import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test, { type TestContext } from "node:test";
import { ConfigurationError, loadConfig } from "./config.js";

const LEGACY_TOKEN = "legacy-token-that-is-long-enough-to-preserve";

test("moves the pre-rename ~/.mocha state to ~/.tavi on first start, keeping devices and identity (#62)", (context) => {
  const homeDirectory = temporaryHome(context);
  const legacyDirectory = path.join(homeDirectory, ".mocha");
  writeConfig(path.join(legacyDirectory, "config.json"), LEGACY_TOKEN);
  writeFileSync(path.join(legacyDirectory, "devices.json"), '{"version":1,"devices":[]}\n', "utf8");
  const notices: string[] = [];

  const config = loadTestConfig(homeDirectory, {}, (message) => notices.push(message));
  const taviDirectory = path.join(homeDirectory, ".tavi");

  assert.equal(config.token, LEGACY_TOKEN);
  assert.equal(config.stateDir, taviDirectory);
  assert.equal(JSON.parse(readFileSync(path.join(taviDirectory, "config.json"), "utf8")).token, LEGACY_TOKEN);
  assert.equal(statExists(path.join(taviDirectory, "devices.json")), true);
  assert.equal(statExists(legacyDirectory), false);
  assert.equal(statSync(path.join(taviDirectory, "config.json")).mode & 0o777, 0o600);
  assert.equal(notices.length, 1);
  assert.match(notices[0] ?? "", /Moved the host state/);
  assert.equal(loadTestConfig(homeDirectory).token, LEGACY_TOKEN);
});

test("rejects conflicting current and pre-rename credentials instead of picking one", (context) => {
  const homeDirectory = temporaryHome(context);
  writeConfig(path.join(homeDirectory, ".mocha", "config.json"), LEGACY_TOKEN);
  writeConfig(path.join(homeDirectory, ".tavi", "config.json"), "different-token-that-is-also-long-enough");

  assert.throws(() => loadTestConfig(homeDirectory), ConfigurationError);
});

test("rejects an invalid moved configuration instead of rotating shell access", (context) => {
  const homeDirectory = temporaryHome(context);
  const legacyDirectory = path.join(homeDirectory, ".mocha");
  mkdirSync(legacyDirectory, { recursive: true });
  writeFileSync(path.join(legacyDirectory, "config.json"), "not-json\n", "utf8");

  assert.throws(() => loadTestConfig(homeDirectory), /configuration is invalid/);
});

test("honours MOCHA_* variables from a pre-rename service plist and reports them once", (context) => {
  const homeDirectory = temporaryHome(context);
  const notices: string[] = [];

  const config = loadTestConfig(
    homeDirectory,
    { MOCHA_PORT: "9999", MOCHA_MACHINE_NAME: "Old", TAVI_MACHINE_NAME: "New" },
    (message) => notices.push(message),
  );

  assert.equal(config.port, 9999);
  assert.equal(config.machineName, "New");
  assert.equal(notices.length, 1);
  assert.match(notices[0] ?? "", /MOCHA_PORT/);
  assert.doesNotMatch(notices[0] ?? "", /MOCHA_MACHINE_NAME/);
});

test("uses only explicit Tavi environment configuration", (context) => {
  const homeDirectory = temporaryHome(context);
  const config = loadTestConfig(homeDirectory, {
    TAVI_HOST: "localhost",
    TAVI_MACHINE_NAME: "Studio",
    TAVI_PORT: "9000",
    TAVI_ROOTS: "/tmp",
    TAVI_TOKEN: "explicit-token-that-is-long-enough",
  });

  assert.equal(config.bindHost, "localhost");
  assert.equal(config.machineName, "Studio");
  assert.equal(config.port, 9000);
  assert.deepEqual(config.roots, ["/tmp"]);
  assert.equal(config.token, "explicit-token-that-is-long-enough");
});

function loadTestConfig(
  homeDirectory: string,
  env: NodeJS.ProcessEnv = {},
  report: (message: string) => void = () => {},
) {
  return loadConfig({
    env: { SHELL: "/bin/zsh", ...env },
    homeDirectory,
    machineHostname: "studio.local",
    operatingSystem: "darwin",
    report,
  });
}

function temporaryHome(context: TestContext): string {
  const directory = mkdtempSync(path.join(tmpdir(), "tavi-config-test-"));
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
