import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { userInfo } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import type { HostConfig } from "./config.js";
import { installService, SERVICE_LABEL } from "./service.js";

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
  execute: (command: string, args: string[]) => Promise<string>;
  which: (command: string) => Promise<string | undefined>;
  healthy: (port: number) => Promise<boolean>;
  installService: () => Promise<void>;
  operatingSystem: NodeJS.Platform;
  userId: number;
  report: (message: string) => void;
  sleep: (ms: number) => Promise<void>;
  now: () => number;
}

export function defaultDeps(config: HostConfig): BootstrapDeps {
  return {
    execute: async (command, args) => {
      const { stdout } = await execFileAsync(command, args, { timeout: 20_000 });
      return stdout;
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
    tailscale.check,
    await checkServe(config, deps, tailscale.cli),
    await checkService(config, deps),
    await checkOptionalTool(deps, "herdr", "Agent cards and launching agents need herdr; the plain terminal works without it.", "Install herdr: https://herdr.dev"),
    await checkOptionalTool(deps, "tmux", "herdr keeps agents alive in tmux so they survive the phone disconnecting.", "brew install tmux"),
  ];
}

/**
 * Fix what can be fixed (install the service, configure Serve), then
 * re-check. Throws with the printed instructions when something still
 * needs a person — installing Tailscale, signing in.
 */
export async function bootstrap(config: HostConfig, deps: BootstrapDeps): Promise<void> {
  const tailscale = await checkTailscale(deps);
  if (!tailscale.check.ok) throw new BootstrapError([tailscale.check]);
  const cli = tailscale.cli as string;

  let serve = await checkServe(config, deps, cli);
  if (!serve.ok) {
    deps.report(`Exposing the host through Tailscale Serve: tailscale serve --bg ${config.port}`);
    try {
      await deps.execute(cli, ["serve", "--bg", String(config.port)]);
    } catch (error) {
      throw new BootstrapError([
        {
          ...serve,
          detail: `${serve.detail} Configuring it failed: ${describe(error)}`,
          fix: `Enable HTTPS certificates for your tailnet (Tailscale admin → DNS → HTTPS Certificates), then run: tailscale serve --bg ${config.port}`,
        },
      ]);
    }
    serve = await checkServe(config, deps, cli);
    if (!serve.ok) throw new BootstrapError([serve]);
  }

  let service = await checkService(config, deps);
  if (!service.ok) {
    if (deps.operatingSystem !== "darwin") throw new BootstrapError([service]);
    deps.report("Installing the Tavi host as a login service (launchd)…");
    await deps.installService();
    const deadline = deps.now() + HEALTH_WAIT_MS;
    while (!(await deps.healthy(config.port))) {
      if (deps.now() >= deadline) {
        throw new BootstrapError([
          {
            ...service,
            detail: `The service was installed but is not answering on port ${config.port} after ${HEALTH_WAIT_MS / 1000}s.`,
            fix: `Check ${path.join(config.stateDir, "host.log")} and \`launchctl print gui/${deps.userId}/${SERVICE_LABEL}\`.`,
          },
        ]);
      }
      await deps.sleep(250);
    }
    service = await checkService(config, deps);
  }

  for (const optional of [
    await checkOptionalTool(deps, "herdr", "Agent cards and launching agents need herdr; the plain terminal works without it.", "Install herdr: https://herdr.dev"),
    await checkOptionalTool(deps, "tmux", "herdr keeps agents alive in tmux so they survive the phone disconnecting.", "brew install tmux"),
  ]) {
    if (!optional.ok) deps.report(`Note: ${optional.name} not found. ${optional.detail} ${optional.fix ?? ""}`.trim());
  }
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

async function checkTailscale(deps: BootstrapDeps): Promise<{ check: Check; cli?: string }> {
  const name = "Tailscale";
  const cli = await deps.which("tailscale");
  if (!cli) {
    return {
      check: {
        name,
        ok: false,
        detail: "Tailscale is not installed. The phone reaches this computer only over your tailnet.",
        fix: "Install Tailscale from https://tailscale.com/download, open it and sign in — on the phone too — then run this again.",
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
  if (deps.operatingSystem !== "darwin") {
    return healthy
      ? { name, ok: true, detail: `running on port ${config.port}` }
      : { name, ok: false, detail: "Not running. Automatic service install is macOS-only for now.", fix: "Run `tavi` in a terminal and keep it open (Linux service: #48)." };
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
    fix: loaded ? `Check ${path.join(config.stateDir, "host.log")}` : "tavi install-service (tavi pair does this for you)",
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
  report(`Installing ${spec} into ${prefix} so the service has a permanent home…`);
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
