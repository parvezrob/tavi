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
  backendState: string;
  serveProxies: string[];
  serviceLoaded: boolean;
  healthy: boolean;
  serveFails?: string;
}

function createDeps(world: World) {
  const commands: string[] = [];
  const reports: string[] = [];
  let clock = 0;
  const deps: BootstrapDeps = {
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
      throw new Error(`unexpected command ${command} ${args.join(" ")}`);
    },
    loadPty: async () => {
      if (world.ptyError) throw new Error(world.ptyError);
    },
    which: async (tool) => world.tools[tool],
    healthy: async () => world.healthy,
    installService: async () => {
      commands.push("install-service");
      world.serviceLoaded = true;
      world.healthy = true;
    },
    operatingSystem: "darwin",
    userId: 501,
    report: (message) => reports.push(message),
    sleep: async (ms) => {
      clock += ms;
    },
    now: () => clock,
  };
  return { deps, commands, reports };
}

const READY: World = {
  tools: { tailscale: "/opt/homebrew/bin/tailscale", herdr: "/opt/homebrew/bin/herdr", tmux: "/opt/homebrew/bin/tmux" },
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
    ["tmux", true],
  ]);
  assert.match(formatChecks(checks), /✓ Tailscale {8}connected as studio.tail1234.ts.net/);
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

test("pair bootstrap configures Serve and installs the service, then waits for health", async () => {
  const world: World = { ...READY, serveProxies: [], serviceLoaded: false, healthy: false };
  const { deps, commands, reports } = createDeps(world);

  await bootstrap(config, deps);

  assert.ok(commands.includes("tailscale serve --bg 8787"), commands.join("\n"));
  assert.ok(commands.includes("install-service"));
  assert.ok(reports.some((line) => /Tailscale Serve/.test(line)));
  assert.ok(reports.some((line) => /login service/.test(line)));
  assert.deepEqual(world.serveProxies, ["http://127.0.0.1:8787"]);
});

test("a missing pty module on Linux names the toolchain to install and how to reinstall", async () => {
  const { deps, commands } = createDeps({ ...READY, ptyError: "Failed to load native module: pty.node, checked: build/Release" });
  deps.operatingSystem = "linux";
  const checks = await diagnose(config, deps);
  assert.equal(checks[0]?.ok, false);
  assert.match(checks[0]?.fix ?? "", /dnf install -y gcc-c\+\+/);
  assert.match(checks[0]?.fix ?? "", /rm -rf ~\/.npm\/_npx/);
  await assert.rejects(() => bootstrap(config, deps), /gcc-c\+\+/);
  assert.ok(!commands.includes("install-service"));
});

test("pair bootstrap stops with the sign-in instruction when Tailscale is stopped", async () => {
  const { deps, commands } = createDeps({ ...READY, backendState: "Stopped" });
  await assert.rejects(() => bootstrap(config, deps), (error: unknown) => {
    assert.ok(error instanceof BootstrapError);
    assert.match(error.message, /Run: tailscale up/);
    return true;
  });
  assert.ok(!commands.includes("install-service"));
});

test("pair bootstrap explains the HTTPS-certificate prerequisite when Serve refuses", async () => {
  const { deps } = createDeps({ ...READY, serveProxies: [], serveFails: "error: HTTPS is not enabled for this tailnet" });
  await assert.rejects(() => bootstrap(config, deps), /HTTPS Certificates.*tailscale serve --bg 8787/s);
});

test("pair bootstrap fails honestly when the installed service never answers", async () => {
  const world: World = { ...READY, serviceLoaded: false, healthy: false };
  const { deps } = createDeps(world);
  deps.installService = async () => {
    world.serviceLoaded = true; // installed, but stays unhealthy
  };
  await assert.rejects(() => bootstrap(config, deps), /not answering on port 8787 after 15s/);
});

test("optional tools only produce a note, never a failure", async () => {
  const { deps, reports } = createDeps({ ...READY, tools: { tailscale: "/usr/bin/tailscale" } });
  await bootstrap(config, deps);
  assert.ok(reports.some((line) => /herdr not found/.test(line)));
  assert.ok(reports.some((line) => /tmux not found/.test(line)));
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
