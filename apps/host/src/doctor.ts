import path from "node:path";
import type { BootstrapDeps } from "./bootstrap-deps.js";
import { type HostConfig, VERSION } from "./config.js";
import { listRemovalLeftovers } from "./removal-sweep.js";
import { SERVICE_LABEL } from "./service.js";
import { LINUX_UNIT } from "./service-linux.js";

// `tavi doctor` (#47): every prerequisite, green or red, nothing changed.
// Each check says what is wrong and the exact next step, so the printed
// output is the whole install guide; `bootstrap.ts` turns the red ones into
// steps it offers to run. Split out of bootstrap.ts in #98.

export interface Check {
  name: string;
  ok: boolean;
  /** The host is running but older than this package. */
  outdated?: boolean;
  /** Missing optional tools degrade features; they never block pairing. */
  optional?: boolean;
  detail: string;
  /** The exact command or action that turns this red check green. */
  fix?: string;
}

/** Read-only: every prerequisite, green or red, nothing changed. */
export async function diagnose(config: HostConfig, deps: BootstrapDeps): Promise<Check[]> {
  const tailscale = await checkTailscale(deps);
  return [
    await checkPty(deps),
    tailscale.check,
    await checkServe(config, deps, tailscale.cli),
    await checkDoor(config, deps, tailscale.cli),
    await checkService(config, deps),
    await checkHerdr(deps),
    ...(await checkCommand(deps)),
    ...(await checkRemovalLeftovers(config)),
  ];
}

// Folders removed worktrees left behind that the host could not delete
// (#82): named, with the command, only when there are any.
async function checkRemovalLeftovers(config: Pick<HostConfig, "roots">): Promise<Check[]> {
  const leftovers = await listRemovalLeftovers(config.roots);
  if (leftovers.length === 0) return [];
  const quoted = leftovers.map((folder) => `'${folder.replaceAll("'", "'\\''")}'`).join(" ");
  return [
    {
      name: "Removed worktrees",
      ok: false,
      optional: true,
      detail: `${leftovers.length} folder${leftovers.length === 1 ? "" : "s"} left by removed worktrees could not be deleted: ${leftovers.join(", ")}`,
      fix: `rm -rf ${quoted}`,
    },
  ];
}

// The `tavi` command (#64): only an install through npx needs one written;
// a checkout or global install has its own and the check stays out of the way.
async function checkCommand(deps: BootstrapDeps): Promise<Check[]> {
  const status = await deps.commandStatus();
  if (!status.needed) return [];
  return [{ name: "`tavi` command", ok: status.ok, detail: status.detail, ...(status.fix ? { fix: status.fix } : {}) }];
}

export function doorCommand(config: HostConfig): string {
  return `tailscale serve --bg --https=${config.previewDoorPort} ${config.previewPort}`;
}

/** Whether Tailscale Serve publishes the preview door right now (the host asks before minting a ticket). */
export async function doorReady(config: HostConfig, deps: Pick<BootstrapDeps, "which" | "execute">): Promise<boolean> {
  const cli = await deps.which("tailscale");
  if (!cli) return false;
  return (await findDoor(config, deps, cli)) !== undefined;
}

async function findDoor(
  config: HostConfig,
  deps: Pick<BootstrapDeps, "execute">,
  cli: string,
): Promise<{ host: string; proxy: string } | undefined> {
  const handlers = await serveHandlers(deps, cli);
  return handlers.find(
    (handler) =>
      new RegExp(`:${config.previewDoorPort}$`).test(handler.host) &&
      new RegExp(`:${config.previewPort}$`).test(handler.proxy),
  );
}

export async function checkDoor(config: HostConfig, deps: BootstrapDeps, cli: string | undefined): Promise<Check> {
  const name = "Preview door";
  const fix = doorCommand(config);
  if (!cli) return { name, ok: false, detail: "Needs Tailscale first.", fix };
  const ours = await findDoor(config, deps, cli);
  if (!ours) {
    return {
      name,
      ok: false,
      detail: `Port ${config.previewPort} is not published as https://…:${config.previewDoorPort}, so dev servers cannot show on the phone.`,
      fix,
    };
  }
  return { name, ok: true, detail: `https://${ours.host} → ${ours.proxy}` };
}

async function serveHandlers(
  deps: Pick<BootstrapDeps, "execute">,
  cli: string,
): Promise<Array<{ host: string; proxy: string }>> {
  try {
    const status = JSON.parse(await deps.execute(cli, ["serve", "status", "--json"])) as {
      Web?: Record<string, { Handlers?: Record<string, { Proxy?: string }> }>;
    };
    return Object.entries(status.Web ?? {}).flatMap(([host, site]) =>
      Object.values(site.Handlers ?? {}).map((handler) => ({ host, proxy: handler.Proxy ?? "" })),
    );
  } catch {
    // No serve config at all prints nothing parseable on some versions.
    return [];
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
export async function checkPty(deps: BootstrapDeps): Promise<Check> {
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

// Read by `bootstrap.ts` too; it lives here because doctor.ts is the module
// bootstrap already imports, and the reverse would be a cycle.
export function firstLine(text: string): string {
  return text.split("\n")[0]?.trim() ?? text;
}

export async function checkTailscale(deps: BootstrapDeps): Promise<{ check: Check; cli?: string }> {
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
    // The CLI is there but did not answer with JSON — reported below as
    // "installed but not responding", which is what the person must fix.
    return {
      check: {
        name,
        ok: false,
        detail: "Tailscale is installed but not responding.",
        fix: "Open the Tailscale app and sign in, then run this again.",
      },
      cli,
    };
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

export async function checkServe(config: HostConfig, deps: BootstrapDeps, cli: string | undefined): Promise<Check> {
  const name = "Tailscale Serve";
  const fix = `tailscale serve --bg ${config.port}`;
  if (!cli) return { name, ok: false, detail: "Needs Tailscale first.", fix };
  const handlers = await serveHandlers(deps, cli);
  const ours = handlers.find(
    (handler) => /:443$/.test(handler.host) && new RegExp(`:${config.port}$`).test(handler.proxy),
  );
  if (!ours) {
    return {
      name,
      ok: false,
      detail: `Port ${config.port} is not exposed as a private HTTPS address on your tailnet.`,
      fix,
    };
  }
  return { name, ok: true, detail: `https://${ours.host.replace(/:443$/, "")} → ${ours.proxy}` };
}

export async function checkService(config: HostConfig, deps: BootstrapDeps): Promise<Check> {
  const name = "Tavi host";
  const running = await deps.healthy(config.port);
  const healthy = running !== undefined;
  // A background service keeps the copy it was installed with; a newer
  // `npx tavi-host pair` must update it, not admire it (ubuntu, 2026-09-01:
  // the service stayed on 0.1.3 while 0.1.5 printed all ✓).
  if (healthy && running !== VERSION) {
    return {
      name,
      ok: false,
      detail: `running an older version (${running}); this is ${VERSION}.`,
      fix: "npx tavi-host install-service (tavi pair offers this)",
      outdated: true,
    };
  }
  if (deps.operatingSystem === "linux") {
    const active = await deps
      .execute("systemctl", ["--user", "is-active", LINUX_UNIT])
      .then((out) => out.trim() === "active")
      .catch(() => false);
    if (healthy && active) return { name, ok: true, detail: `running as ${LINUX_UNIT} on port ${config.port}` };
    if (healthy)
      return {
        name,
        ok: true,
        detail: `running on port ${config.port} (not as a service — it will not survive a reboot)`,
        fix: "tavi install-service",
      };
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
      : {
          name,
          ok: false,
          detail: "Not running. Automatic service install supports macOS and Linux.",
          fix: "Run `tavi` in a terminal and keep it open.",
        };
  }
  const loaded = await deps
    .execute("launchctl", ["print", `gui/${deps.userId}/${SERVICE_LABEL}`])
    .then(() => true)
    .catch(() => false);
  if (healthy && loaded) return { name, ok: true, detail: `running as ${SERVICE_LABEL} on port ${config.port}` };
  if (healthy)
    return {
      name,
      ok: true,
      detail: `running on port ${config.port} (not as a login service — it will not survive a reboot)`,
      fix: "tavi install-service",
    };
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
    return {
      name,
      ok: false,
      optional: true,
      detail: "Not installed. Agent cards and launching agents need it; the plain terminal works without it.",
      fix: "npx tavi-host pair (offers to install it)",
    };
  }
  if (await deps.herdrRunning()) return { name, ok: true, optional: true, detail: `running (${found})` };
  return {
    name,
    ok: false,
    optional: true,
    detail: "Installed but its server is not running, so the app shows no agent cards.",
    fix: "npx tavi-host pair (starts it in the background)",
  };
}

export function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
