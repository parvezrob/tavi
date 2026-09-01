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
import { installHerdrService } from "./herdr-service.js";
import { HerdrService } from "./herdr.js";

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
  /** True when herdr's server answers on its socket. */
  herdrRunning: () => Promise<boolean>;
  /** Starts herdr's server as a background service. */
  startHerdr: (herdrPath: string) => Promise<void>;
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
    herdrRunning: async () => (await new HerdrService({ socketPath: config.herdrSocket }).listAgents()).available,
    startHerdr: async (herdrPath) => {
      await installHerdrService(herdrPath, { userId: userInfo().uid });
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
    await checkHerdr(deps),
  ];
}

interface Step {
  /** What the plan says will happen ("Install Tailscale and sign in"). */
  label: string;
  /** The ✓ line once it has ("Tailscale connected"). */
  done: string;
  optional?: boolean;
  /** Does the work; may return a short detail for the ✓ line. */
  run: () => Promise<string | undefined>;
}

/**
 * Make the machine ready to pair: one checklist of what is already fine and
 * what will be done, one yes/no question, then each step reports a ✓ line.
 * Nothing technical reaches the screen unless a step fails, and then it is
 * one plain sentence plus the log path. Throws with `doctor`'s instructions
 * when the person says no or something still needs them.
 */
export async function bootstrap(config: HostConfig, deps: BootstrapDeps): Promise<void> {
  const pty = await checkPty(deps);
  if (!pty.ok) throw new BootstrapError([pty]);

  const tailscale = await checkTailscale(deps);
  const serve = await checkServe(config, deps, tailscale.cli);
  const service = await checkService(config, deps);
  const herdr = await deps.which("herdr");

  const lines: string[] = ["  ✓ Terminal ready"];
  const steps: Step[] = [];
  const pending: Check[] = [];

  if (tailscale.check.ok) {
    lines.push(`  ✓ Tailscale connected  (${tailscale.check.detail.replace(/^connected as /, "")})`);
  } else {
    const label = tailscale.cli ? "Start Tailscale and sign in" : "Install Tailscale and sign in";
    lines.push(`  • ${label}  — will do`);
    pending.push(tailscale.check);
    steps.push({ label, done: "Tailscale connected", run: () => stepTailscale(deps) });
  }
  if (serve.ok) {
    lines.push(`  ✓ Private address for your phone  (${serve.detail.split(" → ")[0]})`);
  } else {
    lines.push("  • Private address for your phone  — will set up");
    pending.push(serve);
    steps.push({ label: "Private address", done: "Private address", run: () => stepServe(config, deps) });
  }
  if (service.ok) {
    lines.push("  ✓ Tavi runs in the background");
  } else {
    lines.push("  • Run Tavi in the background  — will set up");
    pending.push(service);
    steps.push({ label: "Run Tavi in the background", done: "Tavi runs in the background", run: () => stepService(config, deps) });
  }
  const herdrRunning = herdr ? await deps.herdrRunning() : false;
  if (herdr && herdrRunning) {
    lines.push("  ✓ herdr running  (agent cards)");
  } else if (herdr) {
    lines.push("  • Start herdr in the background, for the agent cards  — will set up");
    steps.push({
      label: "herdr",
      done: "herdr running",
      optional: true,
      run: async () => {
        await deps.startHerdr(herdr);
        await waitFor(deps, () => deps.herdrRunning(), "herdr did not answer");
        return undefined;
      },
    });
  } else {
    const install = installHerdrCommand(deps);
    if (install) {
      lines.push("  • Install herdr and start it, for the agent cards  — will do");
      steps.push({
        label: "herdr",
        done: "herdr running",
        optional: true,
        run: async () => {
          await deps.run(install[0] as string, install.slice(1));
          const installed = await deps.which("herdr");
          if (!installed) throw new Error("herdr was not found after the install");
          await deps.startHerdr(installed);
          await waitFor(deps, () => deps.herdrRunning(), "herdr did not answer");
          return undefined;
        },
      });
    }
  }

  deps.report(`\nTavi — setting up this computer\n\n${lines.join("\n")}\n`);
  if (steps.length === 0) return;

  const count = steps.length === 1 ? "this" : `these ${steps.length} things`;
  if (!(await deps.ask(`Do ${count} now? Your password may be asked once.`))) {
    throw new BootstrapError(pending);
  }
  deps.report("");
  for (const step of steps) {
    try {
      const detail = await step.run();
      deps.report(`  ✓ ${step.done}${detail ? `   ${detail}` : ""}`);
    } catch (error) {
      if (step.optional) {
        deps.report(`  – ${step.label} skipped: ${firstLine(describe(error))}. Tavi still works as a terminal.`);
        continue;
      }
      throw error instanceof BootstrapError ? error : new BootstrapError([{ name: step.label, ok: false, detail: firstLine(describe(error)) }]);
    }
  }
  deps.report("");
}

// Installs and/or starts Tailscale. `tailscale up` prints the sign-in link
// itself and returns once the browser side is done.
async function stepTailscale(deps: BootstrapDeps): Promise<string | undefined> {
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const { check, cli } = await checkTailscale(deps);
    if (check.ok) return check.detail.replace(/^connected as /, "");
    if (!cli) {
      const install = tailscaleInstallCommand(deps);
      if (!install) throw new BootstrapError([check]);
      await deps.run(install[0] as string, install.slice(1));
      continue;
    }
    if (deps.operatingSystem === "linux") await ensureOperator(deps, cli);
    await deps.run(cli, ["up"]).catch(async () => {
      await deps.run("sudo", [cli, "up"]);
    });
  }
  throw new BootstrapError([(await checkTailscale(deps)).check]);
}

async function stepServe(config: HostConfig, deps: BootstrapDeps): Promise<string | undefined> {
  const cli = (await checkTailscale(deps)).cli;
  if (!cli) throw new Error("Tailscale is not available.");
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const serve = await checkServe(config, deps, cli);
    if (serve.ok) return serve.detail.split(" → ")[0];
    try {
      await deps.execute(cli, ["serve", "--bg", String(config.port)]);
    } catch (error) {
      const explained = explainServeFailure(describe(error), config.port);
      if (explained.kind === "operator") {
        await ensureOperator(deps, cli, true);
        continue;
      }
      if (explained.kind === "https") {
        throw new BootstrapError([
          {
            name: "Private address",
            ok: false,
            detail: "Tailscale needs HTTPS certificates turned on for your network (one time).",
            fix: "Open https://login.tailscale.com/admin/dns, turn on “HTTPS Certificates”, then run `npx tavi-host pair` again.",
          },
        ]);
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
    const ok = await deps.execute(cli, ["serve", "status", "--json"]).then(() => true).catch(() => false);
    if (ok) return;
  }
  await deps.run("sudo", [cli, "set", `--operator=${user}`]);
}

async function stepService(config: HostConfig, deps: BootstrapDeps): Promise<string | undefined> {
  const log = path.join(config.stateDir, "host.log");
  try {
    await deps.installService();
    await waitHealthy(config, deps, "Tavi was set up but is not answering");
    return undefined;
  } catch (error) {
    // The person still gets to pair today; the service is Tavi's problem
    // to fix and the details go to the log, not their screen.
    deps.report(`  – Couldn't set Tavi to run in the background here (details in ${log} — please share that file with us).`);
    deps.report(`    Running Tavi for this session instead. (${firstLine(describe(error))})`);
  }
  await deps.startForSession();
  await waitHealthy(config, deps, "Tavi could not start on this computer");
  return "until you log out";
}

async function waitFor(deps: BootstrapDeps, ready: () => Promise<boolean>, problem: string): Promise<void> {
  const deadline = deps.now() + HEALTH_WAIT_MS;
  while (!(await ready())) {
    if (deps.now() >= deadline) throw new Error(`${problem} after ${HEALTH_WAIT_MS / 1000}s.`);
    await deps.sleep(250);
  }
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

async function checkHerdr(deps: BootstrapDeps): Promise<Check> {
  const name = "herdr";
  const found = await deps.which("herdr");
  if (!found) {
    return { name, ok: false, optional: true, detail: "Not installed. Agent cards and launching agents need it; the plain terminal works without it.", fix: "npx tavi-host pair (offers to install it)" };
  }
  if (await deps.herdrRunning()) return { name, ok: true, optional: true, detail: `running (${found})` };
  return { name, ok: false, optional: true, detail: "Installed but its server is not running, so the app shows no agent cards.", fix: "npx tavi-host pair (starts it in the background)" };
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
