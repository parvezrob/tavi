#!/usr/bin/env node
import { AttentionOverlay, AttentionReconciler, AttentiveAgentEvents } from "./attention.js";
import { homedir } from "node:os";
import { removeCommandLink } from "./command-link.js";
import { bootstrap, BootstrapError } from "./bootstrap.js";
import { defaultDeps } from "./bootstrap-deps.js";
import { diagnose, doorReady, formatChecks } from "./doctor.js";
import { chaosStartup, createChaos } from "./chaos.js";
import { durablePackageRoot, isEphemeral, serviceEntrypoint } from "./package-root.js";
import { PreviewRegistry } from "./preview.js";
import { createPreviewDoor } from "./preview-door.js";
import { installClaudeHooks, removeClaudeHooks } from "./claude-hooks.js";
import { uninstallHerdrService } from "./herdr-service.js";
import { uninstall } from "./uninstall.js";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { DeviceRegistry } from "./pairing.js";
import { resolvePublicUrl, runPairCommand } from "./pair-command.js";
import { loadConfig, VERSION } from "./config.js";
import { HerdrService } from "./herdr.js";
import { HerdrEventFeed } from "./herdr-events.js";
import { installService, uninstallService } from "./service.js";
import { isManagedRuntime, runtimeLayout } from "./runtime.js";
import { defaultUpdaterDeps, markStarted, startUpdater, type UpdateOutcome } from "./updater.js";
import { log } from "./log.js";
import { describeSweep, SWEEP_INTERVAL_MS, sweepRemovalLeftovers } from "./removal-sweep.js";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SHUTDOWN_DEADLINE_MS = 2_000;

function describeFailure(error: unknown): string {
  if (error instanceof AggregateError) {
    return [error.message, ...error.errors.map(describeFailure)].join("\n");
  }
  return error instanceof Error ? error.message : String(error);
}

const USAGE = `Tavi host ${VERSION} — pairs your phone with the coding agents on this computer.

Usage: tavi <command>

  pair [--url https://…]   Set everything up, asking before each fix, then show a pairing code
       [--yes]             Answer yes to every question (for scripts)
  doctor                   Check every prerequisite without changing anything
  devices [revoke <id>]    List paired phones, or cut one off
  install-service          Run the host at login (macOS, Linux); uninstall-service removes it
  uninstall                Remove Tavi from this computer entirely (asks first)
  install-claude-hooks     Report Claude Code permission waits to the phone
  update                   Check for a newer Tavi now (the background host also checks daily)
  token                    Print this host's own token (for the CLI, never for a phone)
  help                     This text

With no command, runs the host in the foreground.`;

const command = process.argv[2];
if (command === "help" || command === "--help" || command === "-h") {
  console.log(USAGE);
  process.exit(0);
}
if (command === "--version" || command === "-v") {
  console.log(VERSION);
  process.exit(0);
}

const config = loadConfig();

if (command === "doctor") {
  const checks = await diagnose(config, defaultDeps(config));
  console.log(`Tavi host ${VERSION}\n${formatChecks(checks)}`);
  process.exit(checks.every((check) => check.ok || check.optional) ? 0 : 1);
}

if (process.argv[2] === "token") {
  process.stdout.write(`${config.token}\n`);
  process.exit(0);
}

if (process.argv[2] === "install-service") {
  try {
    const packageRoot = await durablePackageRoot(config);
    const plist = await installService(config, { packageRoot, entrypoint: serviceEntrypoint(config, packageRoot) });
    console.log(`Tavi now starts automatically. LaunchAgent: ${plist}`);
    process.exit(0);
  } catch (error) {
    console.error(`Tavi service installation failed.\n${describeFailure(error)}`);
    process.exit(1);
  }
}

if (command === "uninstall") {
  const deps = defaultDeps(config, { assumeYes: process.argv.includes("--yes") || process.argv.includes("-y") });
  const execFileAsync = promisify(execFile);
  const tailscale = await deps.which("tailscale");
  const removed = await uninstall(config, {
    ask: deps.ask,
    report: deps.report,
    uninstallService: async () => {
      await uninstallService();
    },
    uninstallHerdrService: async () => {
      await uninstallHerdrService();
    },
    removeClaudeHooks,
    removeCommandLink: () => removeCommandLink(homedir()),
    serveHandlers: async () => {
      if (!tailscale) return [];
      try {
        const { stdout } = await execFileAsync(tailscale, ["serve", "status", "--json"], { timeout: 10_000 });
        const status = JSON.parse(stdout) as {
          Web?: Record<string, { Handlers?: Record<string, { Proxy?: string }> }>;
        };
        return Object.entries(status.Web ?? {}).flatMap(([host, site]) =>
          Object.values(site.Handlers ?? {}).map((handler): [string, string] => [host, handler.Proxy ?? ""]),
        );
      } catch {
        // Only used to list what uninstall would remove; a Tailscale that
        // will not answer means nothing of ours is published through it.
        return [];
      }
    },
    resetServe: async () => {
      if (tailscale) await execFileAsync(tailscale, ["serve", "reset"], { timeout: 10_000 });
    },
  });
  process.exit(removed ? 0 : 1);
}

if (process.argv[2] === "uninstall-service") {
  const plists = await uninstallService();
  console.log(`Tavi service removed: ${plists.join(", ")}`);
  process.exit(0);
}

if (process.argv[2] === "pair") {
  try {
    const assumeYes = process.argv.includes("--yes") || process.argv.includes("-y");
    await bootstrap(config, defaultDeps(config, { assumeYes }));
    const publicUrl = await resolvePublicUrl(process.argv.slice(3));
    await runPairCommand(config, publicUrl);
    process.exit(0);
  } catch (error) {
    if (error instanceof BootstrapError) {
      console.error(
        `Not ready to pair yet.\n${error.message}\n\nFix the above (or answer yes next time) and run \`tavi pair\` again; \`tavi doctor\` shows every check.`,
      );
    } else {
      console.error(describeFailure(error));
    }
    process.exit(1);
  }
}

if (process.argv[2] === "devices") {
  const registry = new DeviceRegistry(config.stateDir);
  const action = process.argv[3];
  if (action === "revoke") {
    const target = process.argv[4] ?? "";
    if (registry.revoke(target)) {
      console.log(`Revoked ${target}. That phone can no longer reach this Mac.`);
    } else {
      console.error(`No paired device named or numbered ${target}. Run \`tavi devices\` to list them.`);
      process.exit(1);
    }
    process.exit(0);
  }
  const devices = registry.list();
  if (devices.length === 0) {
    console.log("No phones are paired. Run `tavi pair` to add one.");
  } else {
    for (const device of devices) {
      console.log(`${device.id}  ${device.name}  paired ${device.pairedAt}  last seen ${device.lastSeenAt ?? "never"}`);
    }
  }
  process.exit(0);
}

if (command === "update") {
  const response = await fetch(`http://${config.bindHost}:${config.port}/api/update`, {
    method: "POST",
    headers: { Authorization: `Bearer ${config.token}` },
  }).catch(() => undefined);
  if (!response) {
    console.error("Tavi isn't running in the background on this computer. Run `npx tavi-host pair` first.");
    process.exit(1);
  }
  const outcome = (await response.json()) as UpdateOutcome;
  if (outcome.status === "updated") {
    process.stdout.write(`Updating ${outcome.from} → ${outcome.to}, restarting…`);
    const deadline = Date.now() + 60_000;
    while (Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 1000));
      const health = await fetch(`http://${config.bindHost}:${config.port}/api/health`, {
        signal: AbortSignal.timeout(1500),
      }).catch(() => undefined);
      const body = health?.ok ? ((await health.json().catch(() => ({}))) as { version?: string }) : {};
      if (body.version === outcome.to) {
        console.log(` done. Tavi ${outcome.to} is running.`);
        process.exit(0);
      }
    }
    console.log(" it is taking longer than expected; check `npx tavi-host doctor` in a minute.");
    process.exit(1);
  }
  if (outcome.status === "current") console.log(`Tavi ${outcome.version} is the latest version.`);
  else console.log(`Not updated: ${outcome.reason}`);
  process.exit(outcome.status === "failed" ? 1 : 0);
}

const KNOWN = [
  "token",
  "install-service",
  "uninstall-service",
  "uninstall",
  "pair",
  "devices",
  "install-claude-hooks",
  "update",
];
if (command !== undefined && !KNOWN.includes(command)) {
  console.error(`Unknown command: ${command}\n\n${USAGE}`);
  process.exit(2);
}

if (process.argv[2] === "install-claude-hooks") {
  const { settingsPath, changed } = installClaudeHooks(config);
  console.log(
    changed
      ? `Claude Code hooks installed in ${settingsPath} (backup written alongside). New Claude sessions report permission waits to Tavi.`
      : `Claude Code hooks already installed in ${settingsPath}.`,
  );
  process.exit(0);
}

const herdr = new HerdrService({ socketPath: config.herdrSocket });
const attention = new AttentionOverlay();
const agentEvents = new AttentiveAgentEvents(new HerdrEventFeed(herdr, { socketPath: config.herdrSocket }), attention);
// Hook-reported blocks are checked against the screen so an Esc'd or
// abandoned dialog cannot pin "Needs you" (see AttentionReconciler).
const reconciler = new AttentionReconciler({
  overlay: attention,
  agents: () => agentEvents.latest?.agents ?? [],
  dialogPresent: async (paneId) => {
    const result = await herdr.readDialog(paneId).catch(() => undefined);
    return result && !("available" in result) ? result.present : undefined;
  },
});
reconciler.start();
// server.js pulls in node-pty's native module; loading it lazily keeps
// `doctor`/`pair` working (and able to explain the failure) on a machine
// where that module did not build.
const { createTaviServer } = await import("./server.js");
// Self-update only applies to the managed runtime (~/.tavi/runtime); a
// checkout or global install is whoever installed it's to update.
const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const managed = isManagedRuntime(packageRoot, config.stateDir);
// Fault injection (#111) is a developer's tool: refused before anything
// listens on a production build, the managed runtime, or an npx run.
const chaosDecision = chaosStartup(process.env.TAVI_CHAOS, {
  production: process.env.NODE_ENV === "production",
  managed,
  ephemeral: isEphemeral(packageRoot, process.env),
});
if (!chaosDecision.ok) {
  console.error(chaosDecision.error);
  process.exit(2);
}
const chaos = chaosDecision.enabled ? createChaos() : undefined;
if (chaos) log.warn("chaos", "CHAOS on: this host injects faults");
const autoUpdate = managed && process.env.TAVI_AUTO_UPDATE !== "off";
const updater = autoUpdate
  ? startUpdater(
      defaultUpdaterDeps({
        currentVersion: VERSION,
        layout: runtimeLayout(config.stateDir),
        // SIGTERM runs the graceful shutdown below; the supervisor restarts us on the new version.
        restart: () => setTimeout(() => process.kill(process.pid, "SIGTERM"), 500).unref(),
      }),
    )
  : undefined;
// Dev-server preview (#58): the door is a second loopback listener that
// Tailscale Serve publishes; it forwards only for tickets the API minted.
// Whether Serve publishes it is asked of Tailscale, cached for a minute.
const previews = new PreviewRegistry();
const door = createPreviewDoor({ registry: previews });
const bootstrapDeps = defaultDeps(config);
let doorState: { at: number; ready: boolean } | undefined;
const server = await createTaviServer({
  config,
  herdr,
  ...(chaos ? { chaos } : {}),
  agentEvents,
  attention,
  previews,
  doorReady: async () => {
    if (doorState && Date.now() - doorState.at < 60_000 && doorState.ready) return true;
    const ready = await doorReady(config, bootstrapDeps).catch(() => false);
    doorState = { at: Date.now(), ready };
    return ready;
  },
  update: async () =>
    updater
      ? updater.checkNow()
      : {
          status: "skipped",
          reason: managed
            ? "automatic updates are off (TAVI_AUTO_UPDATE=off)"
            : "this host runs from a checkout or global install; update it there",
        },
});
server.on("close", () => reconciler.stop());
server.on("error", (error: NodeJS.ErrnoException) => {
  if (error.code === "EADDRINUSE") {
    // Almost always a person typing `npx tavi-host` on a computer where the
    // background host is already up (a colleague, 2026-09-01). Not a fault.
    console.error(
      `Tavi is already running on this computer (port ${config.port}) — nothing else to start.\n` +
        "To pair a phone: npx tavi-host pair   ·   To check everything: npx tavi-host doctor",
    );
    process.exit(0);
  }
  console.error(`Tavi could not start: ${error.message}`);
  process.exit(1);
});
door.on("error", (error: NodeJS.ErrnoException) => {
  // The main server's EADDRINUSE handler above explains a second copy; a
  // busy preview port alone only costs previews, so say so and carry on.
  console.error(
    `Dev-server previews are off: the preview port ${config.previewPort} is busy (${error.code ?? error.message}). Set TAVI_PREVIEW_PORT to a free port.`,
  );
});
door.listen(config.previewPort, "127.0.0.1");
server.listen(config.port, config.bindHost, () => {
  if (managed && markStarted(runtimeLayout(config.stateDir), VERSION)) console.log(`Updated to Tavi ${VERSION}.`);
  console.log(`Tavi ${VERSION} is running on http://${config.bindHost}:${config.port}`);
  console.log(`Machine: ${config.machineName}`);
  console.log("Run `tavi pair` to pair a phone.");
  // Folders removed worktrees left behind (#82): retried now and hourly,
  // each outcome one line on the log.
  const sweep = (): void => {
    void sweepRemovalLeftovers(config.roots)
      .then((report) => {
        for (const line of describeSweep(report)) log.warn("removal-sweep", line);
      })
      .catch(() => undefined);
  };
  sweep();
  setInterval(sweep, SWEEP_INTERVAL_MS).unref();
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    door.close();
    door.closeAllConnections?.();
    server.close(() => process.exit(0));
    // Whatever still holds the event loop (a pty mid-teardown, a client that
    // never answers the close frame) must not keep the old instance alive while
    // the installer bootstraps the new one (#21).
    setTimeout(() => process.exit(0), SHUTDOWN_DEADLINE_MS).unref();
  });
}
