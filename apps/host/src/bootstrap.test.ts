import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readlinkSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test, { type TestContext } from "node:test";
import {
  bootstrap,
  BootstrapError,
  type BootstrapDeps,
  diagnose,
  durablePackageRoot,
  formatChecks,
  serviceEntrypoint,
} from "./bootstrap.js";
import { type HostConfig, VERSION } from "./config.js";
import { testConfig } from "./testing/config.js";

const config = testConfig({
  herdrSocket: "/tmp/herdr.sock",
  stateDir: "/home/tester/.tavi",
  machineName: "studio",
});

interface World {
  tools: Record<string, string | undefined>;
  ptyError?: string;
  /** Answers to questions, in order; missing answers are "no". */
  answers?: boolean[];
  os?: NodeJS.Platform;
  serviceFails?: string;
  herdrRunning?: boolean;
  backendState: string;
  serveProxies: string[];
  /** Proxies behind the preview door (:8443). Defaults to one when the host's own address exists (#58). */
  doorProxies?: string[];
  serviceLoaded: boolean;
  healthy: boolean;
  /** Version the running host reports; defaults to this package's. */
  runningVersion?: string;
  serveFails?: string | undefined;
  /** The `tavi` command (#64): needed only for npx installs; ok when on PATH. */
  commandNeeded?: boolean;
  commandOk?: boolean;
}

function createDeps(world: World) {
  const commands: string[] = [];
  const ran: string[] = [];
  const questions: string[] = [];
  const reports: string[] = [];
  const answers = [...(world.answers ?? [])];
  let clock = 0;
  const deps: BootstrapDeps = {
    run: async (command, args) => {
      const line = [command, ...args].join(" ");
      ran.push(line);
      // Simulate what each fix does to the world.
      if (/tailscale\.com\/install|brew install --cask tailscale/.test(line)) {
        world.tools.tailscale = "/usr/bin/tailscale";
        world.backendState = "NeedsLogin";
      } else if (/tailscale up$/.test(line)) {
        world.backendState = "Running";
      } else if (/--operator=/.test(line)) {
        world.serveFails = undefined;
      } else if (/herdr/.test(line)) {
        world.tools.herdr = "/usr/local/bin/herdr";
      } else if (/tmux/.test(line)) {
        world.tools.tmux = "/usr/bin/tmux";
      }
    },
    ask: async (question) => {
      questions.push(question);
      return answers.shift() ?? false;
    },
    env: { USER: "robin" },
    execute: async (command, args) => {
      commands.push([path.basename(command), ...args].join(" "));
      if (args[0] === "status" && args[1] === "--json") {
        return JSON.stringify({ BackendState: world.backendState, Self: { DNSName: "studio.tail1234.ts.net." } });
      }
      if (args[0] === "serve" && args[1] === "status") {
        const site = (proxies: string[]) => ({
          Handlers: Object.fromEntries(proxies.map((proxy, index) => [`/${index || ""}`, { Proxy: proxy }])),
        });
        return JSON.stringify({
          Web: {
            "studio.tail1234.ts.net:443": site(world.serveProxies),
            "studio.tail1234.ts.net:8443": site(world.doorProxies ?? []),
          },
        });
      }
      if (args[0] === "serve" && args[1] === "--bg") {
        if (world.serveFails) throw new Error(world.serveFails);
        // biome-ignore lint/suspicious/noAssignInExpressions: the fake records the first door proxy and every one after it in one line.
        if (args[2]?.startsWith("--https=")) (world.doorProxies ??= []).push(`http://127.0.0.1:${args[3]}`);
        else world.serveProxies.push(`http://127.0.0.1:${args[2]}`);
        return "";
      }
      if (command === "launchctl") {
        if (world.serviceLoaded) return "state = running";
        throw new Error("Could not find service");
      }
      if (command === "systemctl") {
        if (world.serviceLoaded) return "active\n";
        throw new Error("inactive");
      }
      throw new Error(`unexpected command ${command} ${args.join(" ")}`);
    },
    loadPty: async () => {
      if (world.ptyError) throw new Error(world.ptyError);
    },
    which: async (tool) => world.tools[tool],
    healthy: async () => (world.healthy ? (world.runningVersion ?? VERSION) : undefined),
    installService: async () => {
      commands.push("install-service");
      if (world.serviceFails) throw new Error(world.serviceFails);
      world.serviceLoaded = true;
      world.healthy = true;
      world.runningVersion = VERSION;
    },
    startForSession: async () => {
      commands.push("start-for-session");
      world.healthy = true;
      world.runningVersion = VERSION;
    },
    herdrRunning: async () => world.herdrRunning === true,
    startHerdr: async (herdrPath) => {
      commands.push(`start-herdr ${herdrPath}`);
      world.herdrRunning = true;
    },
    commandStatus: async () => ({
      needed: world.commandNeeded === true,
      ok: world.commandNeeded !== true || world.commandOk === true,
      detail: world.commandOk ? "`tavi` is /usr/local/bin/tavi" : "The `tavi` command is not set up.",
    }),
    linkCommand: async () => {
      commands.push("link-command");
      world.commandOk = true;
      return "(/usr/local/bin/tavi)";
    },
    operatingSystem: world.os ?? "darwin",
    userId: 501,
    report: (message) => reports.push(message),
    sleep: async (ms) => {
      clock += ms;
    },
    now: () => clock,
  };
  return { deps, commands, ran, questions, reports };
}

const READY: World = {
  tools: { tailscale: "/opt/homebrew/bin/tailscale", herdr: "/opt/homebrew/bin/herdr" },
  herdrRunning: true,
  backendState: "Running",
  serveProxies: ["http://127.0.0.1:8787"],
  doorProxies: ["http://127.0.0.1:8788"],
  serviceLoaded: true,
  healthy: true,
};

test("doctor reports every check green on a configured machine", async () => {
  const { deps } = createDeps({ ...READY, serveProxies: [...READY.serveProxies] });
  const checks = await diagnose(config, deps);
  assert.deepEqual(
    checks.map((check) => [check.name, check.ok]),
    [
      ["Terminal (pty)", true],
      ["Tailscale", true],
      ["Tailscale Serve", true],
      ["Preview door", true],
      ["Tavi host", true],
      ["herdr", true],
    ],
  );
  assert.match(formatChecks(checks), /✓ Tailscale {8}connected as studio.tail1234.ts.net/);
});

test("doctor names the folders removed worktrees left behind, with the command that clears them (#82)", async () => {
  const root = mkdtempSync(path.join(tmpdir(), "tavi-doctor-leftover-"));
  const leftover = path.join(root, "app-worktrees", "fix-foo.removing-k1x");
  mkdirSync(leftover, { recursive: true });
  const { deps } = createDeps({ ...READY, serveProxies: [...READY.serveProxies] });
  const checks = await diagnose({ ...config, roots: [root] }, deps);
  const check = checks.find((entry) => entry.name === "Removed worktrees");
  assert.equal(check?.ok, false);
  assert.equal(check?.optional, true);
  assert.match(check?.detail ?? "", /1 folder left by removed worktrees could not be deleted/);
  assert.equal(check?.fix, `rm -rf '${leftover}'`);
  rmSync(root, { recursive: true, force: true });
});

test("doctor on Linux reads the systemd unit state", async () => {
  const { deps } = createDeps({ ...READY, os: "linux", serveProxies: [...READY.serveProxies] });
  const checks = await diagnose(config, deps);
  assert.match(checks[4]?.detail ?? "", /running as tavi-host.service/);
});

test("doctor says exactly what to install when Tailscale is missing, and marks herdr optional", async () => {
  const { deps } = createDeps({ ...READY, tools: {}, serveProxies: [], doorProxies: [] });
  const checks = await diagnose(config, deps);
  const [, tailscale, serve, door, , herdr] = checks;
  assert.equal(tailscale?.ok, false);
  assert.match(tailscale?.fix ?? "", /tailscale.com\/download/);
  assert.equal(serve?.ok, false);
  assert.equal(door?.ok, false);
  assert.match(door?.fix ?? "", /tailscale serve --bg --https=8443 8788/);
  assert.equal(herdr?.ok, false);
  assert.equal(herdr?.optional, true);
  assert.match(formatChecks(checks), /– herdr/);
});

test("pair shows one checklist, asks once, then does the work and reports each ✓", async () => {
  const world: World = {
    ...READY,
    serveProxies: [],
    doorProxies: [],
    serviceLoaded: false,
    healthy: false,
    answers: [true],
  };
  const { deps, commands, questions, reports } = createDeps(world);

  await bootstrap(config, deps);

  const plan = reports.find((line) => /setting up this computer/.test(line)) ?? "";
  assert.match(plan, /✓ Terminal ready/);
  assert.match(plan, /✓ Tailscale connected {2}\(studio.tail1234.ts.net\)/);
  assert.match(plan, /• Private address for your phone {2}— will set up/);
  assert.match(plan, /• Private address for previews, so dev servers show on the phone {2}— will set up/);
  assert.match(plan, /• Run Tavi in the background {2}— will set up/);
  assert.match(plan, /✓ herdr running/);
  assert.deepEqual(questions, ["Do these 3 things now? Your password may be asked once."]);
  assert.ok(commands.includes("tailscale serve --bg 8787"), commands.join("\n"));
  assert.ok(commands.includes("tailscale serve --bg --https=8443 8788"), commands.join("\n"));
  assert.ok(
    reports.some((line) => /^ {2}✓ Private address for previews {3}https:\/\/studio.tail1234.ts.net:8443$/.test(line)),
    reports.join("\n"),
  );
  assert.ok(commands.includes("install-service"));
  assert.ok(
    reports.some((line) => /^ {2}✓ Private address {3}https:\/\/studio.tail1234.ts.net$/.test(line)),
    reports.join("\n"),
  );
  assert.ok(reports.some((line) => /^ {2}✓ Tavi runs in the background$/.test(line)));
  assert.ok(!reports.some((line) => /systemctl|launchctl|serve --bg/.test(line)), reports.join("\n"));
});

test("a background host older than this package is updated, not admired (ubuntu 0.1.3 vs 0.1.5)", async () => {
  const world: World = { ...READY, serveProxies: [...READY.serveProxies], runningVersion: "0.1.3", answers: [true] };
  const { deps, commands, reports, questions } = createDeps(world);

  await bootstrap(config, deps);

  assert.match(
    reports[0] ?? "",
    new RegExp(`• Update Tavi in the background to ${VERSION.replaceAll(".", "\\.")}  — will do`),
  );
  assert.deepEqual(questions, ["Do this now? Your password may be asked once."]);
  assert.ok(commands.includes("install-service"));
  assert.ok(
    reports.some((line) => line.includes(`✓ Tavi runs in the background  (${VERSION})`)),
    reports.join("\n"),
  );
  assert.equal(world.runningVersion, VERSION);
});

test("doctor reports an outdated background host with the update command", async () => {
  const { deps } = createDeps({ ...READY, serveProxies: [...READY.serveProxies], runningVersion: "0.1.3" });
  const checks = await diagnose(config, deps);
  const host = checks.find((check) => check.name === "Tavi host");
  assert.equal(host?.ok, false);
  assert.match(host?.detail ?? "", /older version \(0\.1\.3\)/);
  assert.match(host?.fix ?? "", /install-service/);
});

test("nothing to do: the checklist is all ✓ and no question is asked", async () => {
  const { deps, questions, commands } = createDeps({ ...READY, serveProxies: [...READY.serveProxies] });
  await bootstrap(config, deps);
  assert.deepEqual(questions, []);
  assert.ok(!commands.includes("install-service"));
});

test("saying no ends with the doctor instructions and changes nothing", async () => {
  const { deps, commands, ran } = createDeps({ ...READY, serviceLoaded: false, healthy: false, answers: [false] });
  await assert.rejects(() => bootstrap(config, deps), /tavi install-service/);
  assert.ok(!commands.includes("install-service"));
  assert.deepEqual(ran, []);
});

test("Tailscale missing on Linux: the plan says install and sign in; one yes installs it, signs in, and continues", async () => {
  const world: World = {
    ...READY,
    os: "linux",
    tools: { herdr: "/usr/local/bin/herdr" },
    herdrRunning: true,
    answers: [true],
  };
  const { deps, ran, questions, reports } = createDeps(world);

  await bootstrap(config, deps);

  assert.match(reports[0] ?? "", /• Install Tailscale and sign in {2}— will do/);
  assert.equal(questions.length, 1);
  assert.equal(ran[0], "sh -c curl -fsSL https://tailscale.com/install.sh | sh");
  assert.ok(ran.includes("/usr/bin/tailscale up"), ran.join("\n"));
  assert.equal(world.backendState, "Running");
  assert.ok(
    reports.some((line) => /✓ Tailscale connected {3}studio.tail1234.ts.net/.test(line)),
    reports.join("\n"),
  );
});

test("Tailscale missing and the person says no: stops with the download link", async () => {
  const { deps, ran } = createDeps({ ...READY, tools: {}, answers: [false] });
  await assert.rejects(() => bootstrap(config, deps), /tailscale.com\/download/);
  assert.deepEqual(ran, []);
});

test("Tailscale stopped on the Mac: plan says start, yes runs `tailscale up`", async () => {
  const world: World = { ...READY, backendState: "Stopped", answers: [true] };
  const { deps, ran, reports } = createDeps(world);
  await bootstrap(config, deps);
  assert.match(reports[0] ?? "", /• Start Tailscale and sign in/);
  assert.ok(ran.includes("/opt/homebrew/bin/tailscale up"));
});

test("Serve denied on Linux: the operator step happens inside the private-address step, no extra question", async () => {
  const world: World = {
    ...READY,
    os: "linux",
    serveProxies: [],
    doorProxies: [],
    serveFails: "sending serve config: Access denied: serve config denied",
    answers: [true],
  };
  const { deps, ran, questions } = createDeps(world);

  await bootstrap(config, deps);

  assert.equal(questions.length, 1);
  assert.ok(ran.includes("sudo /opt/homebrew/bin/tailscale set --operator=robin"), ran.join("\n"));
  assert.deepEqual(world.serveProxies, ["http://127.0.0.1:8787"]);
});

test("Serve refused for HTTPS certificates: one plain sentence with the admin link, no jargon", async () => {
  const world: World = {
    ...READY,
    serveProxies: [],
    doorProxies: [],
    serveFails: "error: HTTPS is not enabled for this tailnet",
    answers: [true],
  };
  const { deps } = createDeps(world);
  await assert.rejects(
    () => bootstrap(config, deps),
    (error: unknown) => {
      assert.ok(error instanceof BootstrapError);
      assert.match(error.message, /HTTPS certificates turned on/);
      assert.match(error.message, /login.tailscale.com\/admin\/dns/);
      assert.doesNotMatch(error.message, /serve --bg|tailnet/);
      return true;
    },
  );
});

test("when the service cannot start, Tavi runs for the session, says so in plain words, and pairing continues", async () => {
  const world: World = {
    ...READY,
    serviceLoaded: false,
    healthy: false,
    answers: [true],
    serviceFails: "`systemctl --user restart tavi-host.service` failed: bad unit file setting",
  };
  const { deps, commands, reports } = createDeps(world);

  await bootstrap(config, deps);

  assert.ok(commands.includes("start-for-session"), commands.join("\n"));
  const explanation = reports.find((line) => /Couldn't set Tavi to run in the background/.test(line)) ?? "";
  assert.match(explanation, /host\.log/);
  assert.doesNotMatch(explanation, /systemctl/);
  assert.ok(
    reports.some((line) => /✓ Tavi runs in the background {3}until you log out/.test(line)),
    reports.join("\n"),
  );
});

test("pair bootstrap fails honestly when nothing can start the host", async () => {
  const world: World = { ...READY, serviceLoaded: false, healthy: false, answers: [true] };
  const { deps } = createDeps(world);
  deps.installService = async () => {
    world.serviceLoaded = true; // installed, but stays unhealthy
  };
  deps.startForSession = async () => {};
  await assert.rejects(() => bootstrap(config, deps), /could not start on this computer on port 8787 after 15s/);
});

test("herdr installed but not running: the plan starts it in the background", async () => {
  const { deps, commands, reports } = createDeps({ ...READY, herdrRunning: false, answers: [true] });
  await bootstrap(config, deps);
  assert.match(reports[0] ?? "", /• Start herdr in the background, for the agent cards/);
  assert.ok(commands.includes("start-herdr /opt/homebrew/bin/herdr"), commands.join("\n"));
  assert.ok(reports.some((line) => /✓ herdr running/.test(line)));
});

test("herdr is in the plan when missing; a failed install is skipped with a note, never fatal", async () => {
  const yes = createDeps({
    ...READY,
    tools: { tailscale: "/usr/bin/tailscale" },
    herdrRunning: false,
    answers: [true],
  });
  const originalRun = yes.deps.run;
  yes.deps.run = async (command, args) => {
    await originalRun(command, args);
  };
  await bootstrap(config, yes.deps);
  assert.match(yes.reports[0] ?? "", /• Install herdr and start it, for the agent cards {2}— will do/);
  assert.ok(yes.ran.includes("brew install herdr"), yes.ran.join("\n"));
  assert.ok(yes.commands.includes("start-herdr /usr/local/bin/herdr"), yes.commands.join("\n"));
  assert.ok(yes.reports.some((line) => /✓ herdr running/.test(line)));

  const failing = createDeps({
    ...READY,
    tools: { tailscale: "/usr/bin/tailscale" },
    herdrRunning: false,
    answers: [true],
  });
  failing.deps.run = async () => {
    throw new Error("brew: command not found");
  };
  await bootstrap(config, failing.deps);
  assert.ok(
    failing.reports.some((line) => /– herdr skipped: brew: command not found/.test(line)),
    failing.reports.join("\n"),
  );
});

test("non-interactive runs never change anything they were not told to", async () => {
  const { deps, ran, commands } = createDeps({ ...READY, tools: {}, answers: [] });
  await assert.rejects(() => bootstrap(config, deps), BootstrapError);
  assert.deepEqual(ran, []);
  assert.ok(!commands.includes("install-service"));
});

test("a checkout or global install is used in place; the npx cache gets a durable copy", async (context) => {
  const home = temporaryDirectory(context);
  const checkout = path.join(home, "repo", "apps", "host");
  writePackage(checkout, "0.1.0");
  const local: HostConfig = { ...config, stateDir: path.join(home, ".tavi") };

  assert.equal(await durablePackageRoot(local, { packageRoot: checkout, env: {} }), checkout);

  const npx = path.join(home, ".npm", "_npx", "abc123", "node_modules", "tavi-host");
  writePackage(npx, "0.1.0");
  const installs: string[] = [];
  const runtime = path.join(local.stateDir, "runtime", "versions", "0.1.0", "node_modules", "tavi-host");
  const resolved = await durablePackageRoot(local, {
    packageRoot: npx,
    env: {},
    report: () => {},
    execute: async (command, args) => {
      installs.push([command, ...args].join(" "));
      writePackage(runtime, "0.1.0");
      return "";
    },
  });
  assert.equal(resolved, runtime);
  assert.deepEqual(installs, [
    `npm install --prefix ${path.join(local.stateDir, "runtime", "versions", "0.1.0")} --no-audit --no-fund --loglevel=error tavi-host@0.1.0`,
  ]);
  assert.equal(readlinkSync(path.join(local.stateDir, "runtime", "current")), path.join("versions", "0.1.0"));
  assert.equal(existsSync(path.join(local.stateDir, "runtime", "launcher.mjs")), true);
  assert.equal(serviceEntrypoint(local, runtime), path.join(local.stateDir, "runtime", "launcher.mjs"));
  assert.equal(serviceEntrypoint(local, checkout), path.join(checkout, "dist", "index.js"));

  // Same version already there: no second install.
  installs.length = 0;
  assert.equal(await durablePackageRoot(local, { packageRoot: npx, env: {}, execute: async () => "" }), runtime);
  assert.deepEqual(installs, []);
});

test("TAVI_PACKAGE_SPEC overrides what the durable copy is installed from (tarball testing)", async (context) => {
  const home = temporaryDirectory(context);
  const npx = path.join(home, "_npx", "x", "node_modules", "tavi-host");
  writePackage(npx, "0.1.0");
  const local: HostConfig = { ...config, stateDir: path.join(home, ".tavi") };
  const runtime = path.join(local.stateDir, "runtime", "versions", "0.1.0", "node_modules", "tavi-host");
  let spec = "";
  await durablePackageRoot(local, {
    packageRoot: npx,
    env: { TAVI_PACKAGE_SPEC: "/tmp/tavi-host-0.1.0.tgz" },
    report: () => {},
    execute: async (_command, args) => {
      spec = args[args.length - 1] ?? "";
      writePackage(runtime, "0.1.0");
      return "";
    },
  });
  assert.equal(spec, "/tmp/tavi-host-0.1.0.tgz");
});

function writePackage(root: string, version: string): void {
  mkdirSync(path.join(root, "dist"), { recursive: true });
  writeFileSync(path.join(root, "package.json"), JSON.stringify({ name: "tavi-host", version }), "utf8");
  writeFileSync(path.join(root, "dist", "index.js"), "", "utf8");
}

function temporaryDirectory(context: TestContext): string {
  const directory = mkdtempSync(path.join(tmpdir(), "tavi-bootstrap-"));
  context.after(() => rmSync(directory, { recursive: true, force: true }));
  return directory;
}

test("an npx install without the `tavi` command gets one added in the plan; a checkout never hears about it (#64)", async () => {
  const world: World = {
    ...READY,
    serveProxies: [...READY.serveProxies],
    commandNeeded: true,
    commandOk: false,
    answers: [true],
  };
  const { deps, commands, reports } = createDeps(world);
  await bootstrap(config, deps);
  const plan = reports.join("\n");
  assert.match(plan, /• The `tavi` command, for `tavi update` and `tavi doctor` {2}— will add/);
  assert.ok(commands.includes("link-command"));
  assert.match(plan, /✓ `tavi` command ready {3}\(\/usr\/local\/bin\/tavi\)/);

  const checkout = createDeps({ ...READY, serveProxies: [...READY.serveProxies] });
  await bootstrap(config, checkout.deps);
  assert.doesNotMatch(checkout.reports.join("\n"), /tavi` command/);
  const checks = await diagnose(config, checkout.deps);
  assert.ok(!checks.some((check) => check.name.includes("command")));

  const doctor = await diagnose(config, createDeps({ ...world, commandOk: false }).deps);
  const command = doctor.find((check) => check.name === "`tavi` command");
  assert.equal(command?.ok, false);
});
