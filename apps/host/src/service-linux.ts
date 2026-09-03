import { chmod, mkdir, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { HostConfig } from "./config.js";
import type { ServiceOptions } from "./service.js";

// Linux background service (#48): a systemd *user* unit, so it needs no
// root, runs as the person who paired, and reads the same state directory.
// `loginctl enable-linger` keeps it alive after logout and across reboots;
// it is best-effort because some distros gate it behind polkit.
// systemd quoting: ExecStart and Environment take quoted words; path
// settings such as WorkingDirectory do not (a quoted one is "a bad unit
// file setting" — the first ubuntu run, 2026-09-01).
type Execute = (command: string, args: string[]) => Promise<void>;

export const LINUX_UNIT = "tavi-host.service";
export const LINUX_UNIT_DIR = path.join(".config", "systemd", "user");

/** Writes a user unit, reloads, enables it, and (re)starts it. Linger is best-effort. */
export async function installSystemdUnit(
  unit: string,
  contents: string,
  options: { homeDirectory: string; execute: Execute },
): Promise<string> {
  const unitFile = path.join(options.homeDirectory, LINUX_UNIT_DIR, unit);
  await mkdir(path.dirname(unitFile), { recursive: true });
  await writeFile(unitFile, contents, { encoding: "utf8", mode: 0o600 });
  await options.execute("systemctl", ["--user", "daemon-reload"]);
  await options.execute("systemctl", ["--user", "enable", unit]);
  await options.execute("systemctl", ["--user", "restart", unit]);
  await options.execute("loginctl", ["enable-linger"]).catch(() => undefined);
  return unitFile;
}

export async function uninstallSystemdUnit(
  unit: string,
  options: { homeDirectory: string; execute: Execute },
): Promise<string[]> {
  const unitFile = path.join(options.homeDirectory, LINUX_UNIT_DIR, unit);
  await options.execute("systemctl", ["--user", "disable", "--now", unit]).catch(() => undefined);
  await rm(unitFile, { force: true });
  await options.execute("systemctl", ["--user", "daemon-reload"]).catch(() => undefined);
  return [unitFile];
}

export async function installSystemdService(config: HostConfig, options: ServiceOptions = {}): Promise<string> {
  const execute = options.execute ?? defaultExecute;
  const homeDirectory = options.homeDirectory ?? homedir();
  const packageRoot = options.packageRoot ?? path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const unitFile = path.join(homeDirectory, ".config", "systemd", "user", LINUX_UNIT);
  const entrypoint = options.entrypoint ?? path.join(packageRoot, "dist", "index.js");
  const logFile = path.join(config.stateDir, "host.log");

  await mkdir(path.dirname(unitFile), { recursive: true });
  await mkdir(config.stateDir, { recursive: true, mode: 0o700 });
  await chmod(config.stateDir, 0o700);
  await writeFile(logFile, "", { flag: "a", mode: 0o600 });
  await chmod(logFile, 0o600);
  await writeFile(unitFile, systemdUnit({ config, packageRoot, entrypoint, logFile }), {
    encoding: "utf8",
    mode: 0o600,
  });

  await execute("systemctl", ["--user", "daemon-reload"]);
  await execute("systemctl", ["--user", "enable", LINUX_UNIT]);
  // restart covers both "first start" and "upgrade over a running host".
  await execute("systemctl", ["--user", "restart", LINUX_UNIT]);
  await execute("loginctl", ["enable-linger"]).catch(() => undefined);
  return unitFile;
}

export async function uninstallSystemdService(options: ServiceOptions = {}): Promise<string[]> {
  const execute = options.execute ?? defaultExecute;
  const homeDirectory = options.homeDirectory ?? homedir();
  const unitFile = path.join(homeDirectory, ".config", "systemd", "user", LINUX_UNIT);
  await execute("systemctl", ["--user", "disable", "--now", LINUX_UNIT]).catch(() => undefined);
  await rm(unitFile, { force: true });
  await execute("systemctl", ["--user", "daemon-reload"]).catch(() => undefined);
  return [unitFile];
}

function systemdUnit(input: { config: HostConfig; packageRoot: string; entrypoint: string; logFile: string }): string {
  const environment: Record<string, string> = {
    TAVI_HOST: input.config.bindHost,
    TAVI_PORT: String(input.config.port),
    TAVI_STATE_DIR: input.config.stateDir,
    TAVI_MACHINE_NAME: input.config.machineName,
    TAVI_SHELL: input.config.shell,
    TAVI_HERDR_SOCKET: input.config.herdrSocket,
    TAVI_ROOTS: input.config.roots.join(","),
    PATH: process.env.PATH || "/usr/local/bin:/usr/bin:/bin",
    LANG: utf8Locale(),
  };
  const lines = Object.entries(environment).map(([key, value]) => `Environment=${quote(`${key}=${value}`)}`);
  return `[Unit]
Description=Tavi host — pairs your phone with the coding agents on this computer
After=network-online.target

[Service]
Type=simple
ExecStart=${quote(process.execPath)} ${quote(input.entrypoint)}
WorkingDirectory=${input.packageRoot}
Restart=always
RestartSec=2
StandardOutput=append:${input.logFile}
StandardError=append:${input.logFile}
${lines.join("\n")}

[Install]
WantedBy=default.target
`;
}

function quote(value: string): string {
  return `"${value.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
}

function utf8Locale(): string {
  const current = process.env.LC_ALL || process.env.LANG;
  return current && /utf-?8/i.test(current) ? current : "C.UTF-8";
}

async function defaultExecute(command: string, args: string[]): Promise<void> {
  const { execFile } = await import("node:child_process");
  await new Promise<void>((resolve, reject) => {
    execFile(command, args, (error, _stdout, stderr) => {
      if (error)
        reject(
          new Error(`\`${[command, ...args].join(" ")}\` failed${stderr ? `: ${stderr.trim()}` : ""}`, {
            cause: error,
          }),
        );
      else resolve();
    });
  });
}
