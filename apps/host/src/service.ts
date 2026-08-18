import { execFile } from "node:child_process";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { homedir, platform, userInfo } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import type { HostConfig } from "./config.js";

const execFileAsync = promisify(execFile);
const LABEL = "dev.agent-deck.host";

export async function installService(config: HostConfig): Promise<string> {
  assertMac();
  const launchAgents = path.join(homedir(), "Library", "LaunchAgents");
  const plist = path.join(launchAgents, `${LABEL}.plist`);
  const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
  const entrypoint = path.join(projectRoot, "apps", "host", "dist", "index.js");
  const logFile = path.join(config.stateDir, "host.log");
  const domain = `gui/${userInfo().uid}`;

  await mkdir(launchAgents, { recursive: true });
  await mkdir(config.stateDir, { recursive: true, mode: 0o700 });
  await writeFile(plist, launchAgentXml({ config, projectRoot, entrypoint, logFile }), { mode: 0o600 });

  await execFileAsync("launchctl", ["bootout", domain, plist]).catch(() => undefined);
  await execFileAsync("launchctl", ["bootstrap", domain, plist]);
  await execFileAsync("launchctl", ["kickstart", "-k", `${domain}/${LABEL}`]);
  return plist;
}

export async function uninstallService(): Promise<string> {
  assertMac();
  const plist = path.join(homedir(), "Library", "LaunchAgents", `${LABEL}.plist`);
  const domain = `gui/${userInfo().uid}`;
  await execFileAsync("launchctl", ["bootout", domain, plist]).catch(() => undefined);
  await rm(plist, { force: true });
  return plist;
}

function launchAgentXml(input: {
  config: HostConfig;
  projectRoot: string;
  entrypoint: string;
  logFile: string;
}): string {
  const environment: Record<string, string> = {
    DECK_HOST: input.config.bindHost,
    DECK_PORT: String(input.config.port),
    DECK_TOKEN: input.config.token,
    DECK_STATE_DIR: input.config.stateDir,
    DECK_MACHINE_NAME: input.config.machineName,
    DECK_TMUX_BIN: input.config.tmuxBin,
    DECK_SHELL: input.config.shell,
    DECK_ROOTS: input.config.roots.join(","),
    PATH: process.env.PATH || "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
  };
  const envXml = Object.entries(environment)
    .map(([key, value]) => `      <key>${xml(key)}</key>\n      <string>${xml(value)}</string>`)
    .join("\n");

  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
      <string>${xml(process.execPath)}</string>
      <string>${xml(input.entrypoint)}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${xml(input.projectRoot)}</string>
    <key>EnvironmentVariables</key>
    <dict>
${envXml}
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>${xml(input.logFile)}</string>
    <key>StandardErrorPath</key>
    <string>${xml(input.logFile)}</string>
  </dict>
</plist>
`;
}

function xml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
}

function assertMac(): void {
  if (platform() !== "darwin") throw new Error("Automatic service installation currently supports macOS only.");
}
