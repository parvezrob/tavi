import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { access, chmod, mkdir, rename, rm, writeFile } from "node:fs/promises";
import { homedir, platform, userInfo } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import type { HostConfig } from "./config.js";

const execFileAsync = promisify(execFile);
const LABEL = "com.farfield.tavi.host";
// The pre-rename label (#62): booted out and its plist removed on install.
const LEGACY_LABEL = "com.parvezrob.mocha.host";

type Execute = (command: string, args: string[]) => Promise<void>;

export interface ServiceOptions {
  execute?: Execute;
  homeDirectory?: string;
  operatingSystem?: NodeJS.Platform;
  projectRoot?: string;
  userId?: number;
  /** How long to wait for a booted-out service to actually leave launchd. */
  bootoutTimeoutMs?: number;
  /** Poll and retry cadence; tests shorten it. */
  retryIntervalMs?: number;
}

interface ServiceRuntime {
  bootoutTimeoutMs: number;
  currentPlist: string;
  domain: string;
  execute: Execute;
  legacyPlist: string;
  projectRoot: string;
  retryIntervalMs: number;
}

const BOOTSTRAP_ATTEMPTS = 5;
// launchctl's own words for "the old instance is still on its way out":
// bootout has returned but the label is not free yet. Anything else is a real
// error and is reported as such.
const TRANSIENT_BOOTSTRAP_ERROR = /Input\/output error|Operation now in progress|already in progress/i;

export async function installService(config: HostConfig, options: ServiceOptions = {}): Promise<string> {
  const runtime = createRuntime(options);
  const entrypoint = path.join(runtime.projectRoot, "apps", "host", "dist", "index.js");
  const logFile = path.join(config.stateDir, "host.log");
  const legacyExists = await fileExists(runtime.legacyPlist);

  await mkdir(path.dirname(runtime.currentPlist), { recursive: true });
  await mkdir(config.stateDir, { recursive: true, mode: 0o700 });
  // mkdir leaves an existing directory's mode alone, and launchd creates the log
  // with the default umask — keep both owner-only on every install.
  await chmod(config.stateDir, 0o700);
  await writeFile(logFile, "", { flag: "a", mode: 0o600 });
  await chmod(logFile, 0o600);
  await writeFileAtomically(
    runtime.currentPlist,
    launchAgentXml({ config, projectRoot: runtime.projectRoot, entrypoint, logFile }),
  );

  await bootout(runtime, LEGACY_LABEL);
  await bootout(runtime, LABEL);

  try {
    await bootstrap(runtime, LABEL, runtime.currentPlist);
    await rm(runtime.legacyPlist, { force: true });
    return runtime.currentPlist;
  } catch (installationError) {
    await bootout(runtime, LABEL);
    await rm(runtime.currentPlist, { force: true });
    if (legacyExists) {
      try {
        await bootstrap(runtime, LEGACY_LABEL, runtime.legacyPlist);
      } catch (rollbackError) {
        throw new AggregateError(
          [installationError, rollbackError],
          "Tavi service installation failed and the legacy service could not be restored.",
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
    bootoutTimeoutMs: options.bootoutTimeoutMs ?? 30_000,
    currentPlist: path.join(launchAgents, `${LABEL}.plist`),
    domain: `gui/${options.userId ?? userInfo().uid}`,
    execute: options.execute ?? execute,
    legacyPlist: path.join(launchAgents, `${LEGACY_LABEL}.plist`),
    projectRoot:
      options.projectRoot ?? path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../.."),
    retryIntervalMs: options.retryIntervalMs ?? 250,
  };
}

// `launchctl bootout` returns as soon as launchd has *accepted* the removal;
// the old process is still being torn down (seconds, when a phone holds the
// events stream open). Bootstrapping the same label inside that window fails
// with "5: Input/output error" — the whole of #21. Wait for the label to
// really leave the domain before handing it out again.
async function bootout(runtime: ServiceRuntime, label: string): Promise<void> {
  const target = `${runtime.domain}/${label}`;
  await runtime.execute("launchctl", ["bootout", target]).catch(() => undefined);
  const deadline = Date.now() + runtime.bootoutTimeoutMs;
  while (await serviceLoaded(runtime, target)) {
    if (Date.now() >= deadline) {
      throw new Error(
        `${label} is still running ${runtime.bootoutTimeoutMs / 1000}s after \`launchctl bootout ${target}\`. ` +
          `Check \`launchctl print ${target}\` and stop it before installing.`,
      );
    }
    await delay(runtime.retryIntervalMs);
  }
}

async function bootstrap(runtime: ServiceRuntime, label: string, plist: string): Promise<void> {
  for (let attempt = 1; ; attempt += 1) {
    try {
      await runtime.execute("launchctl", ["bootstrap", runtime.domain, plist]);
      break;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (attempt >= BOOTSTRAP_ATTEMPTS || !TRANSIENT_BOOTSTRAP_ERROR.test(message)) throw error;
      await delay(runtime.retryIntervalMs * attempt);
    }
  }
  // RunAtLoad already started it; a plain kickstart only fills in if it did
  // not. `-k` here used to kill the fresh instance and start a second one.
  await runtime.execute("launchctl", ["kickstart", `${runtime.domain}/${label}`]);
}

async function serviceLoaded(runtime: ServiceRuntime, target: string): Promise<boolean> {
  return runtime
    .execute("launchctl", ["print", target])
    .then(() => true)
    .catch(() => false);
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function execute(command: string, args: string[]): Promise<void> {
  try {
    await execFileAsync(command, args);
  } catch (error) {
    const stderr = (error as { stderr?: string }).stderr?.trim();
    throw new Error(
      `\`${[command, ...args].join(" ")}\` failed${stderr ? `: ${stderr}` : ""}`,
      { cause: error },
    );
  }
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
  // TAVI_TOKEN is intentionally absent: the service reads the persisted token
  // from the state directory, so rotation never requires a reinstall.
  const environment: Record<string, string> = {
    TAVI_HOST: input.config.bindHost,
    TAVI_PORT: String(input.config.port),
    TAVI_STATE_DIR: input.config.stateDir,
    TAVI_MACHINE_NAME: input.config.machineName,
    TAVI_SHELL: input.config.shell,
    TAVI_HERDR_SOCKET: input.config.herdrSocket,
    TAVI_ROOTS: input.config.roots.join(","),
    PATH: process.env.PATH || "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    // launchd provides no locale; agents and the pty bridge need UTF-8 so
    // terminal output and herdr's NDJSON are never mangled.
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
