import { randomBytes } from "node:crypto";
import {
  closeSync,
  cpSync,
  existsSync,
  fsyncSync,
  linkSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir, hostname, platform } from "node:os";
import path from "node:path";

export const VERSION = "0.1.14";

const CONFIG_FILE_NAME = "config.json";
const DEFAULT_STATE_DIRECTORY = ".tavi";
// The working name until 2026-09-01 (#62). A host upgraded in place still has
// its pairing state under ~/.mocha and its service plist may still export
// MOCHA_* — both keep working for one release, with a nudge to rename.
const LEGACY_STATE_DIRECTORY = ".mocha";
const LEGACY_ENVIRONMENT_PREFIX = "MOCHA_";
const ENVIRONMENT_PREFIX = "TAVI_";
type EnvironmentKey =
  | "HOST"
  | "PORT"
  | "TOKEN"
  | "STATE_DIR"
  | "MACHINE_NAME"
  | "SHELL"
  | "ROOTS"
  | "HERDR_SOCKET"
  | "PREVIEW_PORT"
  | "PREVIEW_DOOR_PORT";

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
  herdrSocket: string;
  roots: string[];
  stateDir: string;
  machineName: string;
  // Dev-server preview (#58): the host's loopback listener that fronts a
  // person's dev servers, and the HTTPS port Tailscale Serve publishes it
  // on (`https://<name>.ts.net:<previewDoorPort>` → `127.0.0.1:<previewPort>`).
  previewPort: number;
  previewDoorPort: number;
}

export interface LoadConfigOptions {
  env?: NodeJS.ProcessEnv;
  homeDirectory?: string;
  machineHostname?: string;
  operatingSystem?: NodeJS.Platform;
  /** Receives one-line notices (legacy state moved, deprecated variables). */
  report?: (message: string) => void;
}

export class ConfigurationError extends Error {}

export function loadConfig(options: LoadConfigOptions = {}): HostConfig {
  const env = options.env ?? process.env;
  const report = options.report ?? ((message: string) => console.error(message));
  const { read, reportDeprecated } = createEnvironmentReader(env);

  const homeDirectory = options.homeDirectory ?? homedir();
  const operatingSystem = options.operatingSystem ?? platform();
  const machineHostname = options.machineHostname ?? hostname();
  const explicitStateDirectory = read("STATE_DIR")?.trim();
  const stateDir = explicitStateDirectory
    ? path.resolve(explicitStateDirectory)
    : path.join(homeDirectory, DEFAULT_STATE_DIRECTORY);
  const legacyStateDir = explicitStateDirectory
    ? undefined
    : path.join(homeDirectory, LEGACY_STATE_DIRECTORY);
  if (legacyStateDir) migrateLegacyStateDirectory(legacyStateDir, stateDir, report);
  const rawPort = Number.parseInt(read("PORT") || "8787", 10);
  const previewPort = portOr(read("PREVIEW_PORT"), 8788);
  const previewDoorPort = portOr(read("PREVIEW_DOOR_PORT"), 8443);
  // Trim and drop blanks *before* resolving: path.resolve("") is the host
  // process's own working directory, so a stray trailing comma would
  // silently widen the roots — and roots now decide where an agent may be
  // born (#24).
  const configuredRoots = read("ROOTS")
    ?.split(",")
    .map((root) => root.trim())
    .filter((root) => root.length > 0)
    .map((root) => path.resolve(root));

  const config: HostConfig = {
    bindHost: read("HOST") || "127.0.0.1",
    port: Number.isFinite(rawPort) && rawPort > 0 && rawPort < 65_536 ? rawPort : 8787,
    token: read("TOKEN") || getOrCreateToken(stateDir, legacyStateDir),
    shell: read("SHELL") || env.SHELL || (operatingSystem === "win32" ? "powershell.exe" : "/bin/sh"),
    herdrSocket:
      read("HERDR_SOCKET") || path.join(homeDirectory, ".config", "herdr", "herdr.sock"),
    roots: configuredRoots?.length ? configuredRoots : defaultRoots(homeDirectory),
    stateDir,
    machineName: read("MACHINE_NAME") || machineHostname.split(".")[0] || machineHostname,
    previewPort,
    previewDoorPort,
  };
  reportDeprecated(report);
  return config;
}

function portOr(value: string | undefined, fallback: number): number {
  const parsed = Number.parseInt(value ?? "", 10);
  return Number.isFinite(parsed) && parsed > 0 && parsed < 65_536 ? parsed : fallback;
}

// TAVI_* wins; a MOCHA_* value still applies (a service plist written before
// the rename exports them) and is reported once so the owner reinstalls.
function createEnvironmentReader(env: NodeJS.ProcessEnv): {
  read: (key: EnvironmentKey) => string | undefined;
  reportDeprecated: (report: (message: string) => void) => void;
} {
  const deprecated = new Set<string>();
  return {
    read(key) {
      const current = env[`${ENVIRONMENT_PREFIX}${key}`];
      if (current !== undefined) return current;
      const legacyKey = `${LEGACY_ENVIRONMENT_PREFIX}${key}`;
      const legacy = env[legacyKey];
      if (legacy !== undefined) deprecated.add(legacyKey);
      return legacy;
    },
    reportDeprecated(report) {
      if (deprecated.size === 0) return;
      report(
        `Deprecated environment variables in use: ${[...deprecated].join(", ")}. Rename them to ${ENVIRONMENT_PREFIX}* or run \`npm run service:install\` to rewrite the service.`,
      );
    },
  };
}

// First start after the rename: move ~/.mocha (token, paired devices, host
// identity, log) to ~/.tavi in one rename so nothing has to re-pair. If both
// exist the token-conflict check below decides; nothing is merged silently.
function migrateLegacyStateDirectory(
  legacyStateDir: string,
  stateDir: string,
  report: (message: string) => void,
): void {
  if (existsSync(stateDir) || !existsSync(legacyStateDir)) return;
  try {
    renameSync(legacyStateDir, stateDir);
  } catch (error) {
    if (!isCrossDeviceError(error)) throw error;
    cpSync(legacyStateDir, stateDir, { recursive: true, preserveTimestamps: true });
  }
  report(`Moved the host state from ${legacyStateDir} to ${stateDir} (pairing and devices preserved).`);
}

function getOrCreateToken(stateDir: string, legacyStateDir?: string): string {
  mkdirSync(stateDir, { recursive: true, mode: 0o700 });

  const configFile = path.join(stateDir, CONFIG_FILE_NAME);
  const current = readTokenFile(configFile);
  const legacyFile = legacyStateDir ? path.join(legacyStateDir, CONFIG_FILE_NAME) : undefined;
  const legacy = legacyFile ? readTokenFile(legacyFile) : { status: "missing" as const };

  if (current.status === "invalid") {
    throw new ConfigurationError(`Tavi configuration is invalid: ${configFile}`);
  }
  if (current.status === "valid") {
    if (legacy.status === "valid" && legacy.token !== current.token) {
      throw new ConfigurationError(
        `Conflicting Tavi (~/.tavi) and pre-rename (~/.mocha) pairing credentials. Resolve ${configFile} and ${legacyFile} before starting the host.`,
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
      throw new ConfigurationError(`Tavi configuration changed concurrently: ${configFile}`);
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

function isCrossDeviceError(error: unknown): error is NodeJS.ErrnoException {
  return error instanceof Error && "code" in error && error.code === "EXDEV";
}

function isFileExistsError(error: unknown): error is NodeJS.ErrnoException {
  return error instanceof Error && "code" in error && error.code === "EEXIST";
}
