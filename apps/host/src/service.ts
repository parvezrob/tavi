import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { access, mkdir, rename, rm, writeFile } from "node:fs/promises";
import { homedir, platform, userInfo } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import type { HostConfig } from "./config.js";

const execFileAsync = promisify(execFile);
const LABEL = "com.parvezrob.mocha.host";
const LEGACY_LABEL = "dev.agent-deck.host";

type Execute = (command: string, args: string[]) => Promise<void>;

export interface ServiceOptions {
  execute?: Execute;
  homeDirectory?: string;
  operatingSystem?: NodeJS.Platform;
  projectRoot?: string;
  userId?: number;
}

interface ServiceRuntime {
  currentPlist: string;
  domain: string;
  execute: Execute;
  legacyPlist: string;
  projectRoot: string;
}

export async function installService(config: HostConfig, options: ServiceOptions = {}): Promise<string> {
  const runtime = createRuntime(options);
  const entrypoint = path.join(runtime.projectRoot, "apps", "host", "dist", "index.js");
  const logFile = path.join(config.stateDir, "host.log");
  const legacyExists = await fileExists(runtime.legacyPlist);

  await mkdir(path.dirname(runtime.currentPlist), { recursive: true });
  await mkdir(config.stateDir, { recursive: true, mode: 0o700 });
  await writeFileAtomically(
    runtime.currentPlist,
    launchAgentXml({ config, projectRoot: runtime.projectRoot, entrypoint, logFile }),
  );

  await bootout(runtime, LEGACY_LABEL);
  await bootout(runtime, LABEL);

  try {
    await runtime.execute("launchctl", ["bootstrap", runtime.domain, runtime.currentPlist]);
    await runtime.execute("launchctl", ["kickstart", "-k", `${runtime.domain}/${LABEL}`]);
    await rm(runtime.legacyPlist, { force: true });
    return runtime.currentPlist;
  } catch (installationError) {
    await bootout(runtime, LABEL);
    await rm(runtime.currentPlist, { force: true });
    if (legacyExists) {
      try {
        await runtime.execute("launchctl", ["bootstrap", runtime.domain, runtime.legacyPlist]);
        await runtime.execute("launchctl", ["kickstart", "-k", `${runtime.domain}/${LEGACY_LABEL}`]);
      } catch (rollbackError) {
        throw new AggregateError(
          [installationError, rollbackError],
          "Mocha service installation failed and the legacy service could not be restored.",
        );
      }
    }
    throw installationError;
  }
}

export async function uninstallService(options: ServiceOptions = {}): Promise<string[]> {
  const runtime = createRuntime(options);
  await bootout(runtime, LABEL);
  await bootout(runtime, LEGACY_LABEL);
  await rm(runtime.currentPlist, { force: true });
  await rm(runtime.legacyPlist, { force: true });
  return [runtime.currentPlist, runtime.legacyPlist];
}

function createRuntime(options: ServiceOptions): ServiceRuntime {
  const operatingSystem = options.operatingSystem ?? platform();
  if (operatingSystem !== "darwin") {
    throw new Error("Automatic service installation currently supports macOS only.");
  }

  const homeDirectory = options.homeDirectory ?? homedir();
  const launchAgents = path.join(homeDirectory, "Library", "LaunchAgents");
  return {
    currentPlist: path.join(launchAgents, `${LABEL}.plist`),
    domain: `gui/${options.userId ?? userInfo().uid}`,
    execute: options.execute ?? execute,
    legacyPlist: path.join(launchAgents, `${LEGACY_LABEL}.plist`),
    projectRoot:
      options.projectRoot ?? path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../.."),
  };
}

async function bootout(runtime: ServiceRuntime, label: string): Promise<void> {
  await runtime.execute("launchctl", ["bootout", `${runtime.domain}/${label}`]).catch(() => undefined);
}

async function execute(command: string, args: string[]): Promise<void> {
  await execFileAsync(command, args);
}

async function writeFileAtomically(file: string, contents: string): Promise<void> {
  const temporaryFile = path.join(
    path.dirname(file),
    `.${path.basename(file)}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`,
  );
  try {
    await writeFile(temporaryFile, contents, { encoding: "utf8", flag: "wx", mode: 0o600 });
    await rename(temporaryFile, file);
  } finally {
    await rm(temporaryFile, { force: true });
  }
}

async function fileExists(file: string): Promise<boolean> {
  return access(file)
    .then(() => true)
    .catch(() => false);
}

function launchAgentXml(input: {
  config: HostConfig;
  projectRoot: string;
  entrypoint: string;
  logFile: string;
}): string {
  // MOCHA_TOKEN is intentionally absent: the service reads the persisted token
  // from the state directory, so rotation never requires a reinstall.
  const environment: Record<string, string> = {
    MOCHA_HOST: input.config.bindHost,
    MOCHA_PORT: String(input.config.port),
    MOCHA_STATE_DIR: input.config.stateDir,
    MOCHA_MACHINE_NAME: input.config.machineName,
    MOCHA_TMUX_BIN: input.config.tmuxBin,
    MOCHA_SHELL: input.config.shell,
    MOCHA_HERDR_SOCKET: input.config.herdrSocket,
    MOCHA_ROOTS: input.config.roots.join(","),
    PATH: process.env.PATH || "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    // launchd provides no locale; without UTF-8, tmux sanitizes the 
    // field separator in list-format output to "_" and parsing breaks.
    LANG: utf8Locale(),
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

function utf8Locale(): string {
  const current = process.env.LC_ALL || process.env.LANG;
  return current && /utf-?8/i.test(current) ? current : "en_US.UTF-8";
}

function xml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
}
