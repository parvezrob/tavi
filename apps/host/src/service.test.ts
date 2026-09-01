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
  assert.match(contents, /<key>MOCHA_HERDR_SOCKET<\/key>/);
  assert.match(contents, /<key>LANG<\/key>\s*<string>[^<]*UTF-8<\/string>/i);
  assert.doesNotMatch(contents, /<key>MOCHA_TOKEN<\/key>/);
  assert.doesNotMatch(contents, /<key>DECK_/);
  if (process.platform === "darwin") {
    assert.match(execFileSync("plutil", ["-lint", installed], { encoding: "utf8" }), /OK/);
  }
  assert.deepEqual(fixture.launchctl(), [
    `bootout gui/501/${LEGACY_LABEL}`,
    `print gui/501/${LEGACY_LABEL}`,
    `bootout gui/501/${CURRENT_LABEL}`,
    `print gui/501/${CURRENT_LABEL}`,
    `bootstrap gui/501 ${fixture.plist(CURRENT_LABEL)}`,
    `kickstart gui/501/${CURRENT_LABEL}`,
  ]);
});

test("waits for the old instance to leave launchd before bootstrapping the new one (#21)", async (context) => {
  // launchctl bootout returns before the process is gone; the label stays
  // loaded for a while (seconds, when a phone holds the events stream open).
  const fixture = createFixture(context, { loaded: [CURRENT_LABEL], lingerMs: 120 });

  await installService(fixture.config, fixture.options);

  const commands = fixture.launchctl();
  const prints = commands.filter((command) => command === `print gui/501/${CURRENT_LABEL}`);
  assert.ok(prints.length >= 2, `expected repeated polling, saw ${prints.length} print(s)`);
  assert.ok(
    commands.indexOf(`bootstrap gui/501 ${fixture.plist(CURRENT_LABEL)}`) > commands.lastIndexOf(`print gui/501/${CURRENT_LABEL}`),
    "bootstrap must come after the last poll",
  );
  assert.deepEqual(fixture.loaded(), [CURRENT_LABEL]);
});

test("retries bootstrap while launchd still reports the label busy, then succeeds", async (context) => {
  let failures = 2;
  const fixture = createFixture(context, {
    fail: (command) => {
      if (command.startsWith("bootstrap") && failures-- > 0) {
        throw new Error("`launchctl bootstrap` failed: Bootstrap failed: 5: Input/output error");
      }
    },
  });

  await installService(fixture.config, fixture.options);

  const bootstraps = fixture.launchctl().filter((command) => command.startsWith("bootstrap"));
  assert.equal(bootstraps.length, 3);
  assert.deepEqual(fixture.loaded(), [CURRENT_LABEL]);
});

test("gives up with a clear message when the old instance never exits", async (context) => {
  const fixture = createFixture(context, { loaded: [CURRENT_LABEL], lingerMs: Number.POSITIVE_INFINITY });
  fixture.options.bootoutTimeoutMs = 100;

  await assert.rejects(
    () => installService(fixture.config, fixture.options),
    /still running .*launchctl bootout gui\/501\/com\.parvezrob\.mocha\.host/,
  );
  assert.equal(fixture.launchctl().some((command) => command.startsWith("bootstrap")), false);
});

test("restores the legacy service if the Mocha service cannot bootstrap", async (context) => {
  const fixture = createFixture(context, {
    fail: (command) => {
      if (command === `bootstrap gui/501 ${fixture.plist(CURRENT_LABEL)}`) {
        throw new Error("bootstrap failed");
      }
    },
  });
  const legacyPlist = fixture.plist(LEGACY_LABEL);
  mkdirSync(path.dirname(legacyPlist), { recursive: true });
  writeFileSync(legacyPlist, "legacy", "utf8");

  await assert.rejects(() => installService(fixture.config, fixture.options), /bootstrap failed/);

  assert.equal(existsSync(fixture.plist(CURRENT_LABEL)), false);
  assert.equal(existsSync(legacyPlist), true);
  assert.ok(fixture.launchctl().includes(`bootstrap gui/501 ${legacyPlist}`));
  assert.ok(fixture.launchctl().includes(`kickstart gui/501/${LEGACY_LABEL}`));
  assert.deepEqual(fixture.loaded(), [LEGACY_LABEL]);
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

interface FixtureOptions {
  fail?: (command: string) => void;
  /** Labels launchd already has loaded when the install starts. */
  loaded?: string[];
  /** How long a booted-out label keeps answering `launchctl print` (the #21 window). */
  lingerMs?: number;
}

// A small launchd: `bootstrap` loads a label, `bootout` unloads it after
// `lingerMs`, and `print` fails once it is gone — exactly the signals the
// installer relies on.
function createFixture(context: TestContext, fixtureOptions: FixtureOptions = {}) {
  const homeDirectory = mkdtempSync(path.join(tmpdir(), "mocha-service-test-"));
  context.after(() => rmSync(homeDirectory, { recursive: true, force: true }));
  const commands: string[] = [];
  const loaded = new Set(fixtureOptions.loaded ?? []);
  const labelOf = (target: string) => target.slice("gui/501/".length);
  const options: ServiceOptions = {
    execute: async (executable, args) => {
      const command = args.join(" ");
      assert.equal(executable, "launchctl");
      commands.push(command);
      fixtureOptions.fail?.(command);
      const [verb = "", target = ""] = args;
      if (verb === "print" && !loaded.has(labelOf(target))) throw new Error(`Could not find service "${target}"`);
      if (verb === "bootstrap") loaded.add(path.basename(args[2] ?? "", ".plist"));
      if (verb === "bootout") {
        const linger = fixtureOptions.lingerMs ?? 0;
        if (linger === Number.POSITIVE_INFINITY) return;
        if (linger > 0) setTimeout(() => loaded.delete(labelOf(target)), linger);
        else loaded.delete(labelOf(target));
      }
    },
    homeDirectory,
    operatingSystem: "darwin",
    projectRoot: "/project/mocha",
    retryIntervalMs: 10,
    userId: 501,
  };
  const config: HostConfig = {
    bindHost: "127.0.0.1",
    port: 8787,
    token: "test-token-that-is-long-enough",
    shell: "/bin/zsh",
    herdrSocket: "/tmp/mocha-test-herdr.sock",
    roots: ["/project"],
    stateDir: path.join(homeDirectory, ".mocha"),
    machineName: "Studio",
  };

  return {
    config,
    launchctl: () => [...commands],
    loaded: () => [...loaded],
    options,
    plist: (label: string) => path.join(homeDirectory, "Library", "LaunchAgents", `${label}.plist`),
  };
}
