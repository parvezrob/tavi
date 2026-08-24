import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test, { type TestContext } from "node:test";
import type { HostConfig } from "./config.js";
import { installService, type ServiceOptions, uninstallService } from "./service.js";

const CURRENT_LABEL = "com.parvezrob.mocha.host";
const LEGACY_LABEL = "dev.agent-deck.host";

test("installs the Mocha service and removes the stopped legacy plist", async (context) => {
  const fixture = createFixture(context);
  const legacyPlist = fixture.plist(LEGACY_LABEL);
  mkdirSync(path.dirname(legacyPlist), { recursive: true });
  writeFileSync(legacyPlist, "legacy", "utf8");

  const installed = await installService(fixture.config, fixture.options);
  const contents = readFileSync(installed, "utf8");

  assert.equal(installed, fixture.plist(CURRENT_LABEL));
  assert.equal(existsSync(legacyPlist), false);
  assert.match(contents, new RegExp(`<string>${CURRENT_LABEL}</string>`));
  assert.match(contents, /<key>MOCHA_TOKEN<\/key>/);
  assert.doesNotMatch(contents, /<key>DECK_/);
  if (process.platform === "darwin") {
    assert.match(execFileSync("plutil", ["-lint", installed], { encoding: "utf8" }), /OK/);
  }
  assert.deepEqual(fixture.commands.slice(0, 4), [
    `launchctl bootout gui/501/${LEGACY_LABEL}`,
    `launchctl bootout gui/501/${CURRENT_LABEL}`,
    `launchctl bootstrap gui/501 ${fixture.plist(CURRENT_LABEL)}`,
    `launchctl kickstart -k gui/501/${CURRENT_LABEL}`,
  ]);
});

test("restores the legacy service if the Mocha service cannot bootstrap", async (context) => {
  const fixture = createFixture(context, (command) => {
    if (command === `launchctl bootstrap gui/501 ${fixture.plist(CURRENT_LABEL)}`) {
      throw new Error("bootstrap failed");
    }
  });
  const legacyPlist = fixture.plist(LEGACY_LABEL);
  mkdirSync(path.dirname(legacyPlist), { recursive: true });
  writeFileSync(legacyPlist, "legacy", "utf8");

  await assert.rejects(() => installService(fixture.config, fixture.options), /bootstrap failed/);

  assert.equal(existsSync(fixture.plist(CURRENT_LABEL)), false);
  assert.equal(existsSync(legacyPlist), true);
  assert.ok(fixture.commands.includes(`launchctl bootstrap gui/501 ${legacyPlist}`));
  assert.ok(fixture.commands.includes(`launchctl kickstart -k gui/501/${LEGACY_LABEL}`));
});

test("uninstall removes both current and legacy services idempotently", async (context) => {
  const fixture = createFixture(context);
  for (const label of [CURRENT_LABEL, LEGACY_LABEL]) {
    const file = fixture.plist(label);
    mkdirSync(path.dirname(file), { recursive: true });
    writeFileSync(file, label, "utf8");
  }

  const removed = await uninstallService(fixture.options);
  await uninstallService(fixture.options);

  assert.deepEqual(removed, [fixture.plist(CURRENT_LABEL), fixture.plist(LEGACY_LABEL)]);
  assert.equal(removed.some(existsSync), false);
});

function createFixture(context: TestContext, fail?: (command: string) => void) {
  const homeDirectory = mkdtempSync(path.join(tmpdir(), "mocha-service-test-"));
  context.after(() => rmSync(homeDirectory, { recursive: true, force: true }));
  const commands: string[] = [];
  const options: ServiceOptions = {
    execute: async (executable, args) => {
      const command = [executable, ...args].join(" ");
      commands.push(command);
      fail?.(command);
    },
    homeDirectory,
    operatingSystem: "darwin",
    projectRoot: "/project/mocha",
    userId: 501,
  };
  const config: HostConfig = {
    bindHost: "127.0.0.1",
    port: 8787,
    token: "test-token-that-is-long-enough",
    shell: "/bin/zsh",
    tmuxBin: "tmux",
    herdrSocket: "/tmp/mocha-test-herdr.sock",
    roots: ["/project"],
    stateDir: path.join(homeDirectory, ".mocha"),
    machineName: "Studio",
  };

  return {
    commands,
    config,
    options,
    plist: (label: string) => path.join(homeDirectory, "Library", "LaunchAgents", `${label}.plist`),
  };
}
