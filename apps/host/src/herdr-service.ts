import { mkdir, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import { installSystemdUnit, LINUX_UNIT_DIR, uninstallSystemdUnit } from "./service-linux.js";

// herdr's server is what the agent cards, launching, and "needs you" come
// from. Since 0.8 it runs headless with no PTY, so it can live under the
// same supervisors as the Tavi host: a LaunchAgent on macOS, a systemd
// user unit on Linux. Where Homebrew already runs it (`brew services start
// herdr`) the ping check is green and nothing here runs.
export const HERDR_LABEL = "com.farfield.tavi.herdr";
export const HERDR_UNIT = "tavi-herdr.service";

export interface HerdrServiceOptions {
  execute?: (command: string, args: string[]) => Promise<void>;
  homeDirectory?: string;
  operatingSystem?: NodeJS.Platform;
  userId?: number;
}

export async function installHerdrService(herdrPath: string, options: HerdrServiceOptions = {}): Promise<string> {
  const operatingSystem = options.operatingSystem ?? process.platform;
  const homeDirectory = options.homeDirectory ?? homedir();
  const execute = options.execute ?? defaultExecute;
  const logFile = path.join(homeDirectory, ".config", "herdr", "herdr-server.log");
  await mkdir(path.dirname(logFile), { recursive: true });

  if (operatingSystem === "linux") {
    return installSystemdUnit(
      HERDR_UNIT,
      `[Unit]
Description=herdr server (agent cards for Tavi)
After=network-online.target

[Service]
Type=simple
ExecStart="${herdrPath}" server
Restart=always
RestartSec=2
StandardOutput=append:${logFile}
StandardError=append:${logFile}
Environment="PATH=${process.env.PATH || "/usr/local/bin:/usr/bin:/bin"}"
Environment="LANG=${utf8Locale()}"

[Install]
WantedBy=default.target
`,
      { homeDirectory, execute },
    );
  }
  if (operatingSystem !== "darwin") throw new Error("herdr can be started as a service on macOS and Linux only.");

  const plist = path.join(homeDirectory, "Library", "LaunchAgents", `${HERDR_LABEL}.plist`);
  const domain = `gui/${options.userId ?? process.getuid?.() ?? 501}`;
  await mkdir(path.dirname(plist), { recursive: true });
  await writeFile(
    plist,
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${HERDR_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
      <string>${xml(herdrPath)}</string>
      <string>server</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
      <key>PATH</key>
      <string>${xml(process.env.PATH || "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")}</string>
      <key>LANG</key>
      <string>${xml(utf8Locale())}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${xml(logFile)}</string>
    <key>StandardErrorPath</key>
    <string>${xml(logFile)}</string>
  </dict>
</plist>
`,
    { encoding: "utf8", mode: 0o600 },
  );
  await execute("launchctl", ["bootout", `${domain}/${HERDR_LABEL}`]).catch(() => undefined);
  await execute("launchctl", ["bootstrap", domain, plist]);
  return plist;
}

export async function uninstallHerdrService(options: HerdrServiceOptions = {}): Promise<string[]> {
  const operatingSystem = options.operatingSystem ?? process.platform;
  const homeDirectory = options.homeDirectory ?? homedir();
  const execute = options.execute ?? defaultExecute;
  if (operatingSystem === "linux") return uninstallSystemdUnit(HERDR_UNIT, { homeDirectory, execute });
  const plist = path.join(homeDirectory, "Library", "LaunchAgents", `${HERDR_LABEL}.plist`);
  await execute("launchctl", ["bootout", `gui/${options.userId ?? process.getuid?.() ?? 501}/${HERDR_LABEL}`]).catch(
    () => undefined,
  );
  await rm(plist, { force: true });
  return [plist];
}

export { LINUX_UNIT_DIR };

function utf8Locale(): string {
  const current = process.env.LC_ALL || process.env.LANG;
  return current && /utf-?8/i.test(current) ? current : "C.UTF-8";
}

function xml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
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
