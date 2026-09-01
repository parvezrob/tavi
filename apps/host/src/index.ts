#!/usr/bin/env node
import { AttentionOverlay, AttentionReconciler, AttentiveAgentEvents } from "./attention.js";
import { installClaudeHooks } from "./claude-hooks.js";
import { DeviceRegistry } from "./pairing.js";
import { resolvePublicUrl, runPairCommand } from "./pair-command.js";
import { loadConfig, VERSION } from "./config.js";
import { HerdrService } from "./herdr.js";
import { HerdrEventFeed } from "./herdr-events.js";
import { createMochaServer } from "./server.js";
import { installService, uninstallService } from "./service.js";

const SHUTDOWN_DEADLINE_MS = 2_000;

function describeFailure(error: unknown): string {
  if (error instanceof AggregateError) {
    return [error.message, ...error.errors.map(describeFailure)].join("\n");
  }
  return error instanceof Error ? error.message : String(error);
}

const config = loadConfig();

if (process.argv[2] === "token") {
  process.stdout.write(`${config.token}\n`);
  process.exit(0);
}

if (process.argv[2] === "install-service") {
  try {
    const plist = await installService(config);
    console.log(`Mocha now starts automatically. LaunchAgent: ${plist}`);
    process.exit(0);
  } catch (error) {
    console.error(`Mocha service installation failed.\n${describeFailure(error)}`);
    process.exit(1);
  }
}

if (process.argv[2] === "uninstall-service") {
  const plists = await uninstallService();
  console.log(`Mocha service removed: ${plists.join(", ")}`);
  process.exit(0);
}

if (process.argv[2] === "pair") {
  const publicUrl = await resolvePublicUrl(config, process.argv.slice(3));
  await runPairCommand(config, publicUrl);
  process.exit(0);
}

if (process.argv[2] === "devices") {
  const registry = new DeviceRegistry(config.stateDir);
  const action = process.argv[3];
  if (action === "revoke") {
    const target = process.argv[4] ?? "";
    if (registry.revoke(target)) {
      console.log(`Revoked ${target}. That phone can no longer reach this Mac.`);
    } else {
      console.error(`No paired device named or numbered ${target}. Run \`mocha devices\` to list them.`);
      process.exit(1);
    }
    process.exit(0);
  }
  const devices = registry.list();
  if (devices.length === 0) {
    console.log("No phones are paired. Run `mocha pair` to add one.");
  } else {
    for (const device of devices) {
      console.log(`${device.id}  ${device.name}  paired ${device.pairedAt}  last seen ${device.lastSeenAt ?? "never"}`);
    }
  }
  process.exit(0);
}

if (process.argv[2] === "install-claude-hooks") {
  const { settingsPath, changed } = installClaudeHooks(config);
  console.log(
    changed
      ? `Claude Code hooks installed in ${settingsPath} (backup written alongside). New Claude sessions report permission waits to Mocha.`
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
const server = await createMochaServer({ config, herdr, agentEvents, attention });
server.on("close", () => reconciler.stop());
server.listen(config.port, config.bindHost, () => {
  console.log(`Mocha ${VERSION} is running on http://${config.bindHost}:${config.port}`);
  console.log(`Machine: ${config.machineName}`);
  console.log("Run `npm run token` in this folder to reveal the phone pairing token.");
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
