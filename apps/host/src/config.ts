import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir, hostname, platform } from "node:os";
import path from "node:path";

export const VERSION = "0.1.0";

interface StoredConfig {
  token: string;
}

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

function getStateDir(): string {
  return process.env.DECK_STATE_DIR || path.join(homedir(), ".agent-deck");
}

function getOrCreateToken(stateDir: string): string {
  mkdirSync(stateDir, { recursive: true, mode: 0o700 });
  if (process.env.DECK_TOKEN) return process.env.DECK_TOKEN;

  const configFile = path.join(stateDir, "config.json");
  try {
    const stored = JSON.parse(readFileSync(configFile, "utf8")) as StoredConfig;
    if (typeof stored.token === "string" && stored.token.length >= 24) return stored.token;
  } catch {
    // First run or a damaged config. A fresh token is safer than starting open.
  }

  const token = randomBytes(32).toString("base64url");
  writeFileSync(configFile, `${JSON.stringify({ token }, null, 2)}\n`, { mode: 0o600 });
  return token;
}

function defaultRoots(): string[] {
  const candidates = ["Code", "Projects", "Developer", "Documents"].map((name) =>
    path.join(homedir(), name),
  );
  return candidates.filter(existsSync);
}

export function loadConfig(): HostConfig {
  const stateDir = getStateDir();
  const rawPort = Number.parseInt(process.env.DECK_PORT || "8787", 10);
  const configuredRoots = process.env.DECK_ROOTS
    ?.split(",")
    .map((root) => path.resolve(root.trim()))
    .filter(Boolean);

  return {
    bindHost: process.env.DECK_HOST || "127.0.0.1",
    port: Number.isFinite(rawPort) && rawPort > 0 && rawPort < 65536 ? rawPort : 8787,
    token: getOrCreateToken(stateDir),
    shell: process.env.DECK_SHELL || process.env.SHELL || (platform() === "win32" ? "powershell.exe" : "/bin/sh"),
    tmuxBin: process.env.DECK_TMUX_BIN || "tmux",
    roots: configuredRoots?.length ? configuredRoots : defaultRoots(),
    stateDir,
    machineName: process.env.DECK_MACHINE_NAME || hostname().split(".")[0] || hostname(),
  };
}
