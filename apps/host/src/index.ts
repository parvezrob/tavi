#!/usr/bin/env node
import { loadConfig, VERSION } from "./config.js";
import { HerdrService } from "./herdr.js";
import { createMochaServer } from "./server.js";
import { installService, uninstallService } from "./service.js";
import { TmuxService } from "./tmux.js";

const config = loadConfig();

if (process.argv[2] === "token") {
  process.stdout.write(`${config.token}\n`);
  process.exit(0);
}

if (process.argv[2] === "install-service") {
  const plist = await installService(config);
  console.log(`Mocha now starts automatically. LaunchAgent: ${plist}`);
  process.exit(0);
}

if (process.argv[2] === "uninstall-service") {
  const plists = await uninstallService();
  console.log(`Mocha service removed: ${plists.join(", ")}`);
  process.exit(0);
}

const tmux = new TmuxService({ bin: config.tmuxBin, shell: config.shell, roots: config.roots });

try {
  await tmux.version();
} catch {
  console.error(`Mocha requires tmux. Could not run: ${config.tmuxBin} -V`);
  process.exit(1);
}

const herdr = new HerdrService({ socketPath: config.herdrSocket });
const server = await createMochaServer({ config, tmux, herdr });
server.listen(config.port, config.bindHost, () => {
  console.log(`Mocha ${VERSION} is running on http://${config.bindHost}:${config.port}`);
  console.log(`Machine: ${config.machineName}`);
  console.log("Run `npm run token` in this folder to reveal the phone pairing token.");
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
  });
}
