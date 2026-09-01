#!/usr/bin/env node
import { AttentionOverlay, AttentionReconciler, AttentiveAgentEvents } from "./attention.js";
import { bootstrap, BootstrapError, defaultDeps, diagnose, durablePackageRoot, formatChecks } from "./bootstrap.js";
import { installClaudeHooks } from "./claude-hooks.js";
import { DeviceRegistry } from "./pairing.js";
import { resolvePublicUrl, runPairCommand } from "./pair-command.js";
import { loadConfig, VERSION } from "./config.js";
import { HerdrService } from "./herdr.js";
import { HerdrEventFeed } from "./herdr-events.js";
import { installService, uninstallService } from "./service.js";

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
  install-service          Run the host at login (macOS); uninstall-service removes it
  install-claude-hooks     Report Claude Code permission waits to the phone
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
    const plist = await installService(config, { packageRoot: await durablePackageRoot(config) });
    console.log(`Tavi now starts automatically. LaunchAgent: ${plist}`);
    process.exit(0);
  } catch (error) {
    console.error(`Tavi service installation failed.\n${describeFailure(error)}`);
    process.exit(1);
  }
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
    const publicUrl = await resolvePublicUrl(config, process.argv.slice(3));
    await runPairCommand(config, publicUrl);
    process.exit(0);
  } catch (error) {
    if (error instanceof BootstrapError) {
      console.error(`Not ready to pair yet.\n${error.message}\n\nFix the above (or answer yes next time) and run \`tavi pair\` again; \`tavi doctor\` shows every check.`);
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

const KNOWN = ["token", "install-service", "uninstall-service", "pair", "devices", "install-claude-hooks"];
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
const agentEvents = new AttentiveAgentEvents(
  new HerdrEventFeed(herdr, { socketPath: config.herdrSocket }),
  attention,
);
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
const server = await createTaviServer({ config, herdr, agentEvents, attention });
server.on("close", () => reconciler.stop());
server.listen(config.port, config.bindHost, () => {
  console.log(`Tavi ${VERSION} is running on http://${config.bindHost}:${config.port}`);
  console.log(`Machine: ${config.machineName}`);
  console.log("Run `tavi pair` to pair a phone.");
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
    // Whatever still holds the event loop (a pty mid-teardown, a client that
    // never answers the close frame) must not keep the old instance alive while
    // the installer bootstraps the new one (#21).
    setTimeout(() => process.exit(0), SHUTDOWN_DEADLINE_MS).unref();
  });
}
