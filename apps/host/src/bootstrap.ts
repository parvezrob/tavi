import { execFile, spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { userInfo } from "node:os";
import { createInterface } from "node:readline/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import type { HostConfig } from "./config.js";
import { installService, SERVICE_LABEL } from "./service.js";
import { LINUX_UNIT } from "./service-linux.js";

// `tavi pair` on a fresh Mac (#47): everything a tester would otherwise do by
// hand — install the service, expose it through Tailscale Serve, notice a
// missing prerequisite — happens here, and `tavi doctor` reports the same
// checks without changing anything. Each check says what is wrong and the
// exact next step, so the printed output is the whole install guide.

const execFileAsync = promisify(execFile);
const TAILSCALE_APP_CLI = "/Applications/Tailscale.app/Contents/MacOS/Tailscale";
const PACKAGE_NAME = "tavi-host";
const HEALTH_WAIT_MS = 15_000;

export interface Check {
  name: string;
  ok: boolean;
  /** Missing optional tools degrade features; they never block pairing. */
  optional?: boolean;
  detail: string;
  /** The exact command or action that turns this red check green. */
  fix?: string;
}

export interface BootstrapDeps {
  /** Runs a command quietly and returns its stdout (status checks). */
  execute: (command: string, args: string[]) => Promise<string>;
  /** Runs a command on the person's terminal (installs, sign-in links, sudo prompts). */
  run: (command: string, args: string[]) => Promise<void>;
  /** Yes/no question; the default answer is yes. Non-interactive runs answer with `assumeYes`. */
  ask: (question: string) => Promise<boolean>;
  env: NodeJS.ProcessEnv;
  /** Loads the pty native module; rejects with the loader's message when it is missing. */
  loadPty: () => Promise<void>;
  which: (command: string) => Promise<string | undefined>;
  healthy: (port: number) => Promise<boolean>;
  installService: () => Promise<void>;
  /** Runs the host detached from this terminal, for this login session only. */
  startForSession: () => Promise<void>;
  operatingSystem: NodeJS.Platform;
  userId: number;
  report: (message: string) => void;
  sleep: (ms: number) => Promise<void>;
  now: () => number;
}

export function defaultDeps(config: HostConfig, options: { assumeYes?: boolean } = {}): BootstrapDeps {
  const interactive = process.stdin.isTTY === true && process.stdout.isTTY === true;
  return {
    execute: async (command, args) => {
      const { stdout } = await execFileAsync(command, args, { timeout: 20_000 });
      return stdout;
    },
    run: (command, args) =>
      new Promise((resolve, reject) => {
        const child = spawn(command, args, { stdio: "inherit" });
        child.on("error", reject);
        child.on("exit", (code) => (code === 0 ? resolve() : reject(new Error(`\`${[command, ...args].join(" ")}\` exited with ${code}`))));
      }),
    ask: async (question) => {
      if (options.assumeYes) return true;
      if (!interactive) return false;
      const rl = createInterface({ input: process.stdin, output: process.stdout });
      try {
        const answer = (await rl.question(`${question} (Y/n) `)).trim().toLowerCase();
        return answer === "" || answer === "y" || answer === "yes";
      } finally {
        rl.close();
      }
    },
    env: process.env,
    loadPty: async () => {
      await import("node-pty");
    },
    which: async (command) => {
      try {
        const { stdout } = await execFileAsync("which", [command]);
        const found = stdout.trim();
        if (found) return found;
      } catch {
        // Not on PATH; fall through to the known app bundle location.
      }
      return command === "tailscale" && existsSync(TAILSCALE_APP_CLI) ? TAILSCALE_APP_CLI : undefined;
    },
    healthy: async (port) => {
      const response = await fetch(`http://127.0.0.1:${port}/api/health`, {
        signal: AbortSignal.timeout(2_000),
      }).catch(() => undefined);
      return response?.ok === true;
    },
    installService: async () => {
      await installService(config, { packageRoot: await durablePackageRoot(config) });
    },
    startForSession: async () => {
      const root = await durablePackageRoot(config);
      const child = spawn(process.execPath, [path.join(root, "dist", "index.js")], {
        detached: true,
        stdio: "ignore",
        env: { ...process.env, TAVI_STATE_DIR: config.stateDir },
      });
      child.unref();
    },
    operatingSystem: process.platform,
    userId: userInfo().uid,
    report: (message) => console.log(message),
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    now: () => Date.now(),
  };
}

/** Read-only: every prerequisite, green or red, nothing changed. */
export async function diagnose(config: HostConfig, deps: BootstrapDeps): Promise<Check[]> {
  const tailscale = await checkTailscale(deps);
  return [
    await checkPty(deps),
    tailscale.check,
    await checkServe(config, deps, tailscale.cli),
    await checkService(config, deps),
    await checkOptionalTool(deps, "herdr", "Agent cards and launching agents need herdr; the plain terminal works without it.", "Install herdr: https://herdr.dev"),
  ];
}

/**
 * Make the machine ready to pair, asking before each change. Every gap has
 * a yes/no question and a real fix behind it; "no" (or a non-interactive
 * run) ends with the same instructions `doctor` prints. Throws with those
 * instructions when something still needs a person.
 */
export async function bootstrap(config: HostConfig, deps: BootstrapDeps): Promise<void> {
  const pty = await checkPty(deps);
  if (!pty.ok) throw new BootstrapError([pty]);

  const cli = await ensureTailscale(deps);
  await ensureServe(config, deps, cli);
  await ensureService(config, deps);

  await offerTool(deps, "herdr", "herdr isn't installed. It keeps your agents running and gives you the agent cards; without it Tavi is a plain remote terminal. Install it now?", installHerdrCommand(deps));
}

async function ensureTailscale(deps: BootstrapDeps): Promise<string> {
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const { check, cli } = await checkTailscale(deps);
    if (check.ok && cli) return cli;

    if (!cli) {
      const install = tailscaleInstallCommand(deps);
      if (!install || !(await deps.ask("Tailscale isn't installed. It is the private link between your phone and this computer. Install it now?"))) {
        throw new BootstrapError([check]);
      }
      deps.report(`Installing Tailscale: ${install.join(" ")}`);
      await deps.run(install[0] as string, install.slice(1));
      continue;
    }

    // Installed but stopped or signed out. `tailscale up` prints the sign-in
    // link and returns once the browser side is done.
    if (!(await deps.ask("Tailscale is installed but not running. Start it and sign in now?"))) {
      throw new BootstrapError([check]);
    }
    if (deps.operatingSystem === "linux") await ensureOperator(deps, cli);
    deps.report("Starting Tailscale — a sign-in link will appear if this computer is not signed in yet.");
    await deps.run(cli, ["up"]).catch(async () => {
      await deps.run("sudo", [cli, "up"]);
    });
  }
  throw new BootstrapError([(await checkTailscale(deps)).check]);
}

async function ensureServe(config: HostConfig, deps: BootstrapDeps, cli: string): Promise<void> {
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const serve = await checkServe(config, deps, cli);
    if (serve.ok) return;
    deps.report(`Giving the host a private HTTPS address on your tailnet: tailscale serve --bg ${config.port}`);
    try {
      await deps.execute(cli, ["serve", "--bg", String(config.port)]);
      continue;
    } catch (error) {
      const explained = explainServeFailure(describe(error), config.port);
      if (explained.kind === "operator") {
        if (!(await deps.ask("Tailscale only lets root change this. Allow your user to manage Tailscale (asks for your password once)?"))) {
          throw new BootstrapError([{ ...serve, ...explained }]);
        }
        await ensureOperator(deps, cli, true);
        continue;
      }
      if (explained.kind === "https") {
        deps.report(`Tailscale needs HTTPS certificates enabled for your tailnet (one-time): https://login.tailscale.com/admin/dns → HTTPS Certificates.`);
        if (!(await deps.ask("Enabled it? Try again"))) throw new BootstrapError([{ ...serve, ...explained }]);
        continue;
      }
      throw new BootstrapError([{ ...serve, ...explained }]);
    }
  }
  throw new BootstrapError([await checkServe(config, deps, cli)]);
}

async function ensureOperator(deps: BootstrapDeps, cli: string, force = false): Promise<void> {
  const user = deps.env.USER || deps.env.LOGNAME;
  if (!user) return;
  if (!force) {
    // Already allowed if serve status answers without complaint.
    const ok = await deps.execute(cli, ["serve", "status", "--json"]).then(() => true).catch(() => false);
    if (ok) return;
  }
  await deps.run("sudo", [cli, "set", `--operator=${user}`]);
}

async function ensureService(config: HostConfig, deps: BootstrapDeps): Promise<void> {
  const service = await checkService(config, deps);
  if (service.ok) return;
  if (!(await deps.ask("Tavi isn't running in the background yet. Run it whenever you log in, so it is always there for your phone?"))) {
    throw new BootstrapError([service]);
  }
  deps.report("Setting Tavi up to run in the background…");
  const log = path.join(config.stateDir, "host.log");
  try {
    await deps.installService();
    await waitHealthy(config, deps, "The background service was set up but is not answering");
    return;
  } catch (error) {
    // The person still gets to pair today. The service is Tavi's problem
    // to fix, and the details are in the log, not on their screen.
    deps.report(
      `The background service didn't start on this computer, so I'll run Tavi for this session instead. ` +
        `Details are in ${log}; please share that file with us.`,
    );
    deps.report(`(${firstLine(describe(error))})`);
  }
  await deps.startForSession();
  await waitHealthy(config, deps, "Tavi could not start on this computer");
  deps.report("Tavi is running until you log out. Run `npx tavi-host pair` again after the next update to make it permanent.");
}

async function waitHealthy(config: HostConfig, deps: BootstrapDeps, problem: string): Promise<void> {
  const deadline = deps.now() + HEALTH_WAIT_MS;
  while (!(await deps.healthy(config.port))) {
    if (deps.now() >= deadline) {
      throw new Error(`${problem} on port ${config.port} after ${HEALTH_WAIT_MS / 1000}s. See ${path.join(config.stateDir, "host.log")}.`);
    }
    await deps.sleep(250);
  }
}

async function offerTool(deps: BootstrapDeps, tool: string, question: string, install: string[] | undefined): Promise<void> {
  if (await deps.which(tool)) return;
  if (!install) {
    deps.report(`Note: ${tool} isn't installed and I don't know how to install it here.`);
    return;
  }
  if (!(await deps.ask(question))) {
    deps.report(`Skipping ${tool}. You can install it later; \`tavi doctor\` will remind you.`);
    return;
  }
  deps.report(`Installing ${tool}: ${install.join(" ")}`);
  try {
    await deps.run(install[0] as string, install.slice(1));
  } catch (error) {
    deps.report(`${tool} did not install (${firstLine(describe(error))}). Tavi still works as a terminal; run \`tavi doctor\` later.`);
  }
}

function tailscaleInstallCommand(deps: BootstrapDeps): string[] | undefined {
  if (deps.operatingSystem === "darwin") return ["brew", "install", "--cask", "tailscale"];
  if (deps.operatingSystem === "linux") return ["sh", "-c", "curl -fsSL https://tailscale.com/install.sh | sh"];
  return undefined;
}

function installHerdrCommand(deps: BootstrapDeps): string[] | undefined {
  if (deps.operatingSystem === "darwin") return ["brew", "install", "herdr"];
  if (deps.operatingSystem === "linux") return ["sh", "-c", "curl -fsSL https://herdr.dev/install.sh | sh"];
  return undefined;
}

export class BootstrapError extends Error {
  constructor(public readonly checks: Check[]) {
    super(checks.map((check) => `${check.name}: ${check.detail}${check.fix ? `\n  → ${check.fix}` : ""}`).join("\n"));
  }
}

export function formatChecks(checks: Check[]): string {
  return checks
    .map((check) => {
      const mark = check.ok ? "✓" : check.optional ? "–" : "✗";
      const fix = !check.ok && check.fix ? `\n    → ${check.fix}` : "";
      return `  ${mark} ${check.name.padEnd(16)} ${check.detail}${fix}`;
    })
    .join("\n");
}

// node-pty ships prebuilt binaries for macOS and Windows only; on Linux npm
// compiles it at install time, which silently fails without a C++ toolchain
// and only surfaces when the host first spawns a terminal.
async function checkPty(deps: BootstrapDeps): Promise<Check> {
  const name = "Terminal (pty)";
  try {
    await deps.loadPty();
    return { name, ok: true, detail: "native module loads" };
  } catch (error) {
    const linux = deps.operatingSystem === "linux";
    return {
      name,
      ok: false,
      detail: `node-pty's native module is missing (${firstLine(describe(error))}).`,
      fix: linux
        ? "Install a C++ toolchain — Fedora: sudo dnf install -y gcc-c++ make python3 · Debian/Ubuntu: sudo apt install -y build-essential python3 — then reinstall: rm -rf ~/.npm/_npx && npx tavi-host doctor"
        : "Reinstall the package: rm -rf ~/.npm/_npx && npx tavi-host doctor (or `npm rebuild node-pty` in a checkout).",
    };
  }
}

// Tailscale's own error text names the real cause; pass the right one on
// rather than guessing. On Linux the CLI needs root or an operator user to
// change serve config; HTTPS certs are a one-time tailnet setting.
function explainServeFailure(message: string, port: number): { kind: "operator" | "https" | "other"; detail: string; fix: string } {
  const command = `tailscale serve --bg ${port}`;
  if (/Access denied|serve config denied|operator/i.test(message)) {
    return {
      kind: "operator",
      detail: "Tailscale would not let this user change its serve config (Linux needs root or an operator user).",
      fix: `Run once: sudo tailscale set --operator=$USER — then run \`tavi pair\` again (or: sudo ${command}).`,
    };
  }
  if (/HTTPS|cert|MagicDNS/i.test(message)) {
    return {
      kind: "https",
      detail: `Tailscale refused: ${firstLine(message)}`,
      fix: `Enable HTTPS certificates for your tailnet (Tailscale admin → DNS → HTTPS Certificates), then run: ${command}`,
    };
  }
  return { kind: "other", detail: `Configuring it failed: ${firstLine(message)}`, fix: `Run ${command} yourself and read Tailscale's message.` };
}

function firstLine(text: string): string {
  return text.split("\n")[0]?.trim() ?? text;
}

async function checkTailscale(deps: BootstrapDeps): Promise<{ check: Check; cli?: string }> {
  const name = "Tailscale";
  const cli = await deps.which("tailscale");
  if (!cli) {
    return {
      check: {
        name,
        ok: false,
        detail: "Tailscale is not installed. The phone reaches this computer only over your tailnet.",
        fix: "Install Tailscale from https://tailscale.com/download and sign in — on the phone too — then run `tavi pair` again (it offers to install it for you).",
      },
    };
  }
  let status: { BackendState?: string; Self?: { DNSName?: string } } = {};
  try {
    status = JSON.parse(await deps.execute(cli, ["status", "--json"])) as typeof status;
  } catch {
    return { check: { name, ok: false, detail: "Tailscale is installed but not responding.", fix: "Open the Tailscale app and sign in, then run this again." }, cli };
  }
  if (status.BackendState !== "Running") {
    return {
      check: {
        name,
        ok: false,
        detail: `Tailscale is ${status.BackendState === "NeedsLogin" ? "not signed in" : "stopped"} on this computer, so its tailnet name resolves nowhere.`,
        fix: status.BackendState === "NeedsLogin" ? "Open the Tailscale app and sign in." : "Run: tailscale up",
      },
      cli,
    };
  }
  const dnsName = status.Self?.DNSName?.replace(/\.$/, "");
  return { check: { name, ok: true, detail: `connected as ${dnsName ?? "(no MagicDNS name)"}` }, cli };
}

async function checkServe(config: HostConfig, deps: BootstrapDeps, cli: string | undefined): Promise<Check> {
  const name = "Tailscale Serve";
  const fix = `tailscale serve --bg ${config.port}`;
  if (!cli) return { name, ok: false, detail: "Needs Tailscale first.", fix };
  let handlers: Array<{ host: string; proxy: string }> = [];
  try {
    const status = JSON.parse(await deps.execute(cli, ["serve", "status", "--json"])) as {
      Web?: Record<string, { Handlers?: Record<string, { Proxy?: string }> }>;
    };
    handlers = Object.entries(status.Web ?? {}).flatMap(([host, site]) =>
      Object.values(site.Handlers ?? {}).map((handler) => ({ host, proxy: handler.Proxy ?? "" })),
    );
  } catch {
    // No serve config at all prints nothing parseable on some versions.
  }
  const ours = handlers.find((handler) => new RegExp(`:${config.port}$`).test(handler.proxy));
  if (!ours) {
    return { name, ok: false, detail: `Port ${config.port} is not exposed as a private HTTPS address on your tailnet.`, fix };
  }
  return { name, ok: true, detail: `https://${ours.host.replace(/:443$/, "")} → ${ours.proxy}` };
}

async function checkService(config: HostConfig, deps: BootstrapDeps): Promise<Check> {
  const name = "Tavi host";
  const healthy = await deps.healthy(config.port);
  if (deps.operatingSystem === "linux") {
    const active = await deps
      .execute("systemctl", ["--user", "is-active", LINUX_UNIT])
      .then((out) => out.trim() === "active")
      .catch(() => false);
    if (healthy && active) return { name, ok: true, detail: `running as ${LINUX_UNIT} on port ${config.port}` };
    if (healthy) return { name, ok: true, detail: `running on port ${config.port} (not as a service — it will not survive a reboot)`, fix: "tavi install-service" };
    return {
      name,
      ok: false,
      detail: active ? `${LINUX_UNIT} is active but not answering on port ${config.port}.` : "Not installed yet.",
      fix: active ? `Check ${path.join(config.stateDir, "host.log")}` : "tavi install-service (tavi pair offers this)",
    };
  }
  if (deps.operatingSystem !== "darwin") {
    return healthy
      ? { name, ok: true, detail: `running on port ${config.port}` }
      : { name, ok: false, detail: "Not running. Automatic service install supports macOS and Linux.", fix: "Run `tavi` in a terminal and keep it open." };
  }
  const loaded = await deps
    .execute("launchctl", ["print", `gui/${deps.userId}/${SERVICE_LABEL}`])
    .then(() => true)
    .catch(() => false);
  if (healthy && loaded) return { name, ok: true, detail: `running as ${SERVICE_LABEL} on port ${config.port}` };
  if (healthy) return { name, ok: true, detail: `running on port ${config.port} (not as a login service — it will not survive a reboot)`, fix: "tavi install-service" };
  return {
    name,
    ok: false,
    detail: loaded ? `${SERVICE_LABEL} is loaded but not answering on port ${config.port}.` : "Not installed yet.",
    fix: loaded ? `Check ${path.join(config.stateDir, "host.log")}` : "tavi install-service (tavi pair offers this)",
  };
}

async function checkOptionalTool(deps: BootstrapDeps, tool: string, detail: string, fix: string): Promise<Check> {
  const found = await deps.which(tool);
  return found
    ? { name: tool, ok: true, optional: true, detail: found }
    : { name: tool, ok: false, optional: true, detail, fix };
}

// `npx tavi-host` runs from npm's ephemeral cache, which is no place for a
// login service to live: the cache gets pruned and a later `npx` of a newer
// version would not touch the service. So the first pair installs a durable
// copy under ~/.tavi/runtime and the service runs from there. A git checkout
// or `npm i -g` is already durable and is used in place.
export async function durablePackageRoot(
  config: HostConfig,
  options: {
    packageRoot?: string;
    execute?: (command: string, args: string[]) => Promise<string>;
    report?: (message: string) => void;
    env?: NodeJS.ProcessEnv;
  } = {},
): Promise<string> {
  const packageRoot = options.packageRoot ?? currentPackageRoot();
  const env = options.env ?? process.env;
  if (!isEphemeral(packageRoot, env)) return packageRoot;

  const version = readVersion(packageRoot);
  const prefix = path.join(config.stateDir, "runtime");
  const target = path.join(prefix, "node_modules", PACKAGE_NAME);
  if (existsSync(target) && readVersion(target) === version) return target;

  const spec = env.TAVI_PACKAGE_SPEC ?? `${PACKAGE_NAME}@${version}`;
  const report = options.report ?? ((message: string) => console.log(message));
  report("Keeping a permanent copy of Tavi on this computer (one moment)…");
  const execute =
    options.execute ??
    (async (command: string, args: string[]) => (await execFileAsync(command, args, { timeout: 180_000 })).stdout);
  await execute("npm", ["install", "--prefix", prefix, "--no-audit", "--no-fund", "--loglevel=error", spec]);
  if (!existsSync(path.join(target, "dist", "index.js"))) {
    throw new Error(`npm reported success but ${target} has no dist/index.js.`);
  }
  return target;
}

function isEphemeral(packageRoot: string, env: NodeJS.ProcessEnv): boolean {
  return packageRoot.split(path.sep).includes("_npx") || env.npm_command === "exec";
}

function currentPackageRoot(): string {
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
}

function readVersion(packageRoot: string): string {
  try {
    return (JSON.parse(readFileSync(path.join(packageRoot, "package.json"), "utf8")) as { version?: string }).version ?? "";
  } catch {
    return "";
  }
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
