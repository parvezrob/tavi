import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test, { type TestContext } from "node:test";
import { bootstrap, BootstrapError, type BootstrapDeps, diagnose, durablePackageRoot, formatChecks } from "./bootstrap.js";
import type { HostConfig } from "./config.js";

const config: HostConfig = {
  bindHost: "127.0.0.1",
  port: 8787,
  token: "token-that-is-long-enough-for-tests",
  shell: "/bin/zsh",
  herdrSocket: "/tmp/herdr.sock",
  roots: [],
  stateDir: "/home/tester/.tavi",
  machineName: "studio",
};

interface World {
  tools: Record<string, string | undefined>;
  ptyError?: string;
  /** Answers to questions, in order; missing answers are "no". */
  answers?: boolean[];
  os?: NodeJS.Platform;
  serviceFails?: string;
  backendState: string;
  serveProxies: string[];
  serviceLoaded: boolean;
  healthy: boolean;
  serveFails?: string | undefined;
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
        const handlers = Object.fromEntries(world.serveProxies.map((proxy, index) => [`/${index || ""}`, { Proxy: proxy }]));
        return JSON.stringify({ Web: { "studio.tail1234.ts.net:443": { Handlers: handlers } } });
      }
      if (args[0] === "serve" && args[1] === "--bg") {
        if (world.serveFails) throw new Error(world.serveFails);
        world.serveProxies.push(`http://127.0.0.1:${args[2]}`);
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
    healthy: async () => world.healthy,
    installService: async () => {
      commands.push("install-service");
      if (world.serviceFails) throw new Error(world.serviceFails);
      world.serviceLoaded = true;
      world.healthy = true;
    },
    startForSession: async () => {
      commands.push("start-for-session");
      world.healthy = true;
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
  backendState: "Running",
  serveProxies: ["http://127.0.0.1:8787"],
  serviceLoaded: true,
  healthy: true,
};

test("doctor reports every check green on a configured machine", async () => {
  const { deps } = createDeps({ ...READY, serveProxies: [...READY.serveProxies] });
  const checks = await diagnose(config, deps);
  assert.deepEqual(checks.map((check) => [check.name, check.ok]), [
    ["Terminal (pty)", true],
    ["Tailscale", true],
    ["Tailscale Serve", true],
    ["Tavi host", true],
    ["herdr", true],
  ]);
  assert.match(formatChecks(checks), /✓ Tailscale {8}connected as studio.tail1234.ts.net/);
});

test("doctor on Linux reads the systemd unit state", async () => {
  const { deps } = createDeps({ ...READY, os: "linux", serveProxies: [...READY.serveProxies] });
  const checks = await diagnose(config, deps);
  assert.match(checks[3]?.detail ?? "", /running as tavi-host.service/);
});

test("doctor says exactly what to install when Tailscale is missing, and marks herdr optional", async () => {
  const { deps } = createDeps({ ...READY, tools: {}, serveProxies: [] });
  const checks = await diagnose(config, deps);
  const [, tailscale, serve, , herdr] = checks;
  assert.equal(tailscale?.ok, false);
  assert.match(tailscale?.fix ?? "", /tailscale.com\/download/);
  assert.equal(serve?.ok, false);
  assert.equal(herdr?.ok, false);
  assert.equal(herdr?.optional, true);
  assert.match(formatChecks(checks), /– herdr/);
});

test("pair asks before each fix and does them: Serve, then the login service, then waits for health", async () => {
  const world: World = { ...READY, serveProxies: [], serviceLoaded: false, healthy: false, answers: [true] };
  const { deps, commands, questions, reports } = createDeps(world);

  await bootstrap(config, deps);

  assert.ok(commands.includes("tailscale serve --bg 8787"), commands.join("\n"));
  assert.equal(questions.length, 1);
  assert.match(questions[0] ?? "", /Run it whenever you log in/);
  assert.ok(commands.includes("install-service"));
  assert.ok(reports.some((line) => /run in the background/.test(line)));
  assert.deepEqual(world.serveProxies, ["http://127.0.0.1:8787"]);
});

test("declining the service install ends with the doctor instructions instead of a half-set-up machine", async () => {
  const { deps, commands } = createDeps({ ...READY, serviceLoaded: false, healthy: false, answers: [false] });
  await assert.rejects(() => bootstrap(config, deps), /tavi install-service/);
  assert.ok(!commands.includes("install-service"));
});

test("Tailscale missing on Linux: offers the install, then the sign-in, then continues to pairing", async () => {
  const world: World = { ...READY, os: "linux", tools: { herdr: "/usr/local/bin/herdr" }, answers: [true, true] };
  const { deps, ran, questions } = createDeps(world);

  await bootstrap(config, deps);

  assert.match(questions[0] ?? "", /Tailscale isn't installed.*Install it now\?/);
  assert.match(questions[1] ?? "", /not running\. Start it and sign in now\?/);
  assert.equal(ran[0], "sh -c curl -fsSL https://tailscale.com/install.sh | sh");
  assert.ok(ran.includes("/usr/bin/tailscale up"), ran.join("\n"));
  assert.equal(world.backendState, "Running");
});

test("Tailscale missing and the person says no: stops with the download link", async () => {
  const { deps, ran } = createDeps({ ...READY, tools: {}, answers: [false] });
  await assert.rejects(() => bootstrap(config, deps), /tailscale.com\/download/);
  assert.deepEqual(ran, []);
});

test("Tailscale stopped on the Mac: one question, then `tailscale up`", async () => {
  const world: World = { ...READY, backendState: "Stopped", answers: [true] };
  const { deps, ran } = createDeps(world);
  await bootstrap(config, deps);
  assert.ok(ran.includes("/opt/homebrew/bin/tailscale up"));
});

test("Serve denied on Linux: asks to make the user an operator, runs the sudo command, then Serve succeeds", async () => {
  const world: World = { ...READY, os: "linux", serveProxies: [], serveFails: "sending serve config: Access denied: serve config denied", answers: [true] };
  const { deps, ran, questions } = createDeps(world);

  await bootstrap(config, deps);

  assert.match(questions[0] ?? "", /Allow your user to manage Tailscale/);
  assert.ok(ran.includes("sudo /opt/homebrew/bin/tailscale set --operator=robin"), ran.join("\n"));
  assert.deepEqual(world.serveProxies, ["http://127.0.0.1:8787"]);
});

test("Serve refused for HTTPS certificates: explains the one-time admin setting and retries on yes", async () => {
  const world: World = { ...READY, serveProxies: [], serveFails: "error: HTTPS is not enabled for this tailnet", answers: [true] };
  const { deps, reports } = createDeps(world);
  // The person enables it in the browser before answering.
  deps.ask = async () => {
    world.serveFails = undefined;
    return true;
  };
  await bootstrap(config, deps);
  assert.ok(reports.some((line) => /admin\/dns/.test(line)));
  assert.deepEqual(world.serveProxies, ["http://127.0.0.1:8787"]);
});

test("when the service cannot start, Tavi runs for the session, says so in plain words, and pairing continues", async () => {
  const world: World = { ...READY, serviceLoaded: false, healthy: false, answers: [true], serviceFails: "`systemctl --user restart tavi-host.service` failed: bad unit file setting" };
  const { deps, commands, reports } = createDeps(world);

  await bootstrap(config, deps);

  assert.ok(commands.includes("start-for-session"), commands.join("\n"));
  const explanation = reports.find((line) => /didn't start on this computer/.test(line)) ?? "";
  assert.match(explanation, /run Tavi for this session/);
  assert.match(explanation, /host\.log/);
  assert.doesNotMatch(explanation, /systemctl/);
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

test("herdr is offered: installed on yes, skipped with a note on no", async () => {
  const yes = createDeps({ ...READY, tools: { tailscale: "/usr/bin/tailscale" }, answers: [true] });
  await bootstrap(config, yes.deps);
  assert.ok(yes.ran.includes("brew install herdr"), yes.ran.join("\n"));

  const no = createDeps({ ...READY, tools: { tailscale: "/usr/bin/tailscale" }, answers: [false] });
  await bootstrap(config, no.deps);
  assert.ok(!no.ran.some((line) => /herdr/.test(line)));
  assert.ok(no.reports.some((line) => /Skipping herdr/.test(line)));
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
  const runtime = path.join(local.stateDir, "runtime", "node_modules", "tavi-host");
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
    `npm install --prefix ${path.join(local.stateDir, "runtime")} --no-audit --no-fund --loglevel=error tavi-host@0.1.0`,
  ]);

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
  const runtime = path.join(local.stateDir, "runtime", "node_modules", "tavi-host");
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
