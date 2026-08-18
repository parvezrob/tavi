import { randomBytes } from "node:crypto";
import {
  closeSync,
  existsSync,
  fsyncSync,
  linkSync,
  mkdirSync,
  openSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir, hostname, platform } from "node:os";
import path from "node:path";

export const VERSION = "0.1.0";

const CONFIG_FILE_NAME = "config.json";
const DEFAULT_STATE_DIRECTORY = ".mocha";
const LEGACY_STATE_DIRECTORY = ".agent-deck";
const LEGACY_ENVIRONMENT_KEYS = [
  "DECK_HOST",
  "DECK_PORT",
  "DECK_TOKEN",
  "DECK_STATE_DIR",
  "DECK_MACHINE_NAME",
  "DECK_TMUX_BIN",
  "DECK_SHELL",
  "DECK_ROOTS",
] as const;

interface StoredConfig {
  token: string;
}

type TokenFileState =
  | { status: "missing" }
  | { status: "valid"; token: string }
  | { status: "invalid" };

export interface HostConfig {
  bindHost: string;
  port: number;
  token: string;
  shell: string;
  tmuxBin: string;
  roots: string[];
  stateDir: string;
  machineName: string;
}

export interface LoadConfigOptions {
  env?: NodeJS.ProcessEnv;
  homeDirectory?: string;
  machineHostname?: string;
  operatingSystem?: NodeJS.Platform;
}

export class ConfigurationError extends Error {}

export function loadConfig(options: LoadConfigOptions = {}): HostConfig {
  const env = options.env ?? process.env;
  assertNoLegacyEnvironment(env);

  const homeDirectory = options.homeDirectory ?? homedir();
  const operatingSystem = options.operatingSystem ?? platform();
  const machineHostname = options.machineHostname ?? hostname();
  const explicitStateDirectory = env.MOCHA_STATE_DIR?.trim();
  const stateDir = explicitStateDirectory
    ? path.resolve(explicitStateDirectory)
    : path.join(homeDirectory, DEFAULT_STATE_DIRECTORY);
  const legacyStateDir = explicitStateDirectory
    ? undefined
    : path.join(homeDirectory, LEGACY_STATE_DIRECTORY);
  const rawPort = Number.parseInt(env.MOCHA_PORT || "8787", 10);
  const configuredRoots = env.MOCHA_ROOTS
    ?.split(",")
    .map((root) => path.resolve(root.trim()))
    .filter(Boolean);

  return {
    bindHost: env.MOCHA_HOST || "127.0.0.1",
    port: Number.isFinite(rawPort) && rawPort > 0 && rawPort < 65_536 ? rawPort : 8787,
    token: env.MOCHA_TOKEN || getOrCreateToken(stateDir, legacyStateDir),
    shell: env.MOCHA_SHELL || env.SHELL || (operatingSystem === "win32" ? "powershell.exe" : "/bin/sh"),
    tmuxBin: env.MOCHA_TMUX_BIN || "tmux",
    roots: configuredRoots?.length ? configuredRoots : defaultRoots(homeDirectory),
    stateDir,
    machineName: env.MOCHA_MACHINE_NAME || machineHostname.split(".")[0] || machineHostname,
  };
}

function getOrCreateToken(stateDir: string, legacyStateDir?: string): string {
  mkdirSync(stateDir, { recursive: true, mode: 0o700 });

  const configFile = path.join(stateDir, CONFIG_FILE_NAME);
  const current = readTokenFile(configFile);
  const legacyFile = legacyStateDir ? path.join(legacyStateDir, CONFIG_FILE_NAME) : undefined;
  const legacy = legacyFile ? readTokenFile(legacyFile) : { status: "missing" as const };

  if (current.status === "invalid") {
    throw new ConfigurationError(`Mocha configuration is invalid: ${configFile}`);
  }
  if (current.status === "valid") {
    if (legacy.status === "valid" && legacy.token !== current.token) {
      throw new ConfigurationError(
        `Conflicting Mocha and legacy pairing credentials. Resolve ${configFile} and ${legacyFile} before starting the host.`,
      );
    }
    return current.token;
  }
  if (legacy.status === "invalid") {
    throw new ConfigurationError(`Legacy configuration is invalid and cannot be migrated: ${legacyFile}`);
  }

  const token = legacy.status === "valid" ? legacy.token : randomBytes(32).toString("base64url");
  return createTokenFileAtomically(configFile, token);
}

function readTokenFile(file: string): TokenFileState {
  if (!existsSync(file)) return { status: "missing" };
  try {
    const stored = JSON.parse(readFileSync(file, "utf8")) as StoredConfig;
    return typeof stored.token === "string" && stored.token.length >= 24
      ? { status: "valid", token: stored.token }
      : { status: "invalid" };
  } catch {
    return { status: "invalid" };
  }
}

function createTokenFileAtomically(configFile: string, token: string): string {
  const stateDir = path.dirname(configFile);
  const temporaryFile = path.join(
    stateDir,
    `.${CONFIG_FILE_NAME}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`,
  );
  let descriptor: number | undefined;

  try {
    descriptor = openSync(temporaryFile, "wx", 0o600);
    writeFileSync(descriptor, `${JSON.stringify({ token }, null, 2)}\n`, "utf8");
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;

    try {
      linkSync(temporaryFile, configFile);
      syncDirectory(stateDir);
      return token;
    } catch (error) {
      if (!isFileExistsError(error)) throw error;
      const concurrent = readTokenFile(configFile);
      if (concurrent.status === "valid" && concurrent.token === token) return token;
      throw new ConfigurationError(`Mocha configuration changed concurrently: ${configFile}`);
    }
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
    try {
      unlinkSync(temporaryFile);
    } catch {
      // The temporary file may already be absent after an interrupted or completed cleanup.
    }
  }
}

function syncDirectory(directory: string): void {
  let descriptor: number | undefined;
  try {
    descriptor = openSync(directory, "r");
    fsyncSync(descriptor);
  } catch {
    // Some platforms do not allow fsync on directories; the file itself is already durable.
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

function defaultRoots(homeDirectory: string): string[] {
  const candidates = ["Code", "Projects", "Developer", "Documents"].map((name) =>
    path.join(homeDirectory, name),
  );
  return candidates.filter(existsSync);
}

function assertNoLegacyEnvironment(env: NodeJS.ProcessEnv): void {
  const present = LEGACY_ENVIRONMENT_KEYS.filter((key) => env[key] !== undefined);
  if (present.length === 0) return;
  throw new ConfigurationError(
    `Legacy Agent Deck environment variables are no longer supported: ${present.join(", ")}. Rename them to MOCHA_* or reinstall the host service.`,
  );
}

function isFileExistsError(error: unknown): error is NodeJS.ErrnoException {
  return error instanceof Error && "code" in error && error.code === "EEXIST";
}
