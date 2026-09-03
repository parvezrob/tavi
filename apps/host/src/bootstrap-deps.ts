import { execFile, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir, userInfo } from "node:os";
import { createInterface } from "node:readline/promises";
import { promisify } from "node:util";
import {
  COMMAND_NAME,
  chooseBinDir,
  commandLinkStatus,
  pathHint,
  writeCommandLink,
  type CommandLinkStatus,
} from "./command-link.js";
import type { HostConfig } from "./config.js";
import { HerdrService } from "./herdr.js";
import { installHerdrService } from "./herdr-service.js";
import { resolveOnLoginPath } from "./login-shell.js";
import { currentPackageRoot, durablePackageRoot, isEphemeral, serviceEntrypoint } from "./package-root.js";
import { isManagedRuntime, runtimeLayout } from "./runtime.js";
import { installService } from "./service.js";

// Everything the install checklist and `doctor` do to the machine, behind
// one injectable interface (#47) — so the tests drive the whole flow without
// a Tailscale, a launchd, or a terminal. Split out of bootstrap.ts in #98.

const execFileAsync = promisify(execFile);
const TAILSCALE_APP_CLI = "/Applications/Tailscale.app/Contents/MacOS/Tailscale";

export interface BootstrapDeps {
  /** Runs a command quietly and returns its stdout (status checks). */
  execute: (command: string, args: string[]) => Promise<string>;
  /** Runs a command on the person's terminal (installs, sign-in links, sudo prompts). */
  run: (command: string, args: string[]) => Promise<void>;
  /** Yes/no question; the default answer is yes. Non-interactive runs answer with `assumeYes`. */
  ask: (question: string) => Promise<boolean>;
  env: NodeJS.ProcessEnv;
  /** Loads the pty native module; rejects with the loader's message when it is missing. */
  loadPty: () => Promise<void>;
  which: (command: string) => Promise<string | undefined>;
  /** The running host's version when it answers on the port, else undefined. */
  healthy: (port: number) => Promise<string | undefined>;
  installService: () => Promise<void>;
  /** True when herdr's server answers on its socket. */
  herdrRunning: () => Promise<boolean>;
  /** Starts herdr's server as a background service. */
  startHerdr: (herdrPath: string) => Promise<void>;
  /** Runs the host detached from this terminal, for this login session only. */
  startForSession: () => Promise<void>;
  /** Whether this install needs a `tavi` command on PATH and whether it has one (#64). */
  commandStatus: () => Promise<CommandLinkStatus>;
  /** Writes the `tavi` shim; returns the ✓ detail (where, and a PATH hint when needed). */
  linkCommand: () => Promise<string | undefined>;
  operatingSystem: NodeJS.Platform;
  userId: number;
  report: (message: string) => void;
  sleep: (ms: number) => Promise<void>;
  now: () => number;
}

export function defaultDeps(config: HostConfig, options: { assumeYes?: boolean } = {}): BootstrapDeps {
  const interactive = process.stdin.isTTY === true && process.stdout.isTTY === true;
  return {
    execute: async (command, args) => {
      const { stdout } = await execFileAsync(command, args, { timeout: 20_000 });
      return stdout;
    },
    run: (command, args) =>
      new Promise((resolve, reject) => {
        const child = spawn(command, args, { stdio: "inherit" });
        child.on("error", reject);
        child.on("exit", (code) =>
          code === 0 ? resolve() : reject(new Error(`\`${[command, ...args].join(" ")}\` exited with ${code}`)),
        );
      }),
    ask: async (question) => {
      if (options.assumeYes) return true;
      if (!interactive) return false;
      const rl = createInterface({ input: process.stdin, output: process.stdout });
      try {
        const answer = (await rl.question(`${question} (Y/n) `)).trim().toLowerCase();
        return answer === "" || answer === "y" || answer === "yes";
      } finally {
        rl.close();
      }
    },
    env: process.env,
    loadPty: async () => {
      await import("node-pty");
    },
    which: async (command) => {
      // The login shell's PATH, not the service's bare one (#103): `which`
      // here missed anything a version manager or ~/.local/bin provides,
      // which is exactly what resolveOnLoginPath exists to find.
      const found = await resolveOnLoginPath(config.shell, command);
      if (found) return found;
      return command === "tailscale" && existsSync(TAILSCALE_APP_CLI) ? TAILSCALE_APP_CLI : undefined;
    },
    healthy: async (port) => {
      const response = await fetch(`http://127.0.0.1:${port}/api/health`, {
        signal: AbortSignal.timeout(2_000),
      }).catch(() => undefined);
      if (!response?.ok) return undefined;
      const body = (await response.json().catch(() => ({}))) as { version?: unknown };
      return typeof body.version === "string" ? body.version : "unknown";
    },
    installService: async () => {
      const packageRoot = await durablePackageRoot(config);
      await installService(config, { packageRoot, entrypoint: serviceEntrypoint(config, packageRoot) });
    },
    herdrRunning: async () => (await new HerdrService({ socketPath: config.herdrSocket }).listAgents()).available,
    startHerdr: async (herdrPath) => {
      await installHerdrService(herdrPath, { userId: userInfo().uid });
    },
    startForSession: async () => {
      const root = await durablePackageRoot(config);
      const child = spawn(process.execPath, [serviceEntrypoint(config, root)], {
        detached: true,
        stdio: "ignore",
        env: { ...process.env, TAVI_STATE_DIR: config.stateDir },
      });
      child.unref();
    },
    commandStatus: async () => {
      const packageRoot = currentPackageRoot();
      const needed = isEphemeral(packageRoot, process.env) || isManagedRuntime(packageRoot, config.stateDir);
      // Same login-shell PATH the person types `tavi` into (#103).
      const resolved = (await resolveOnLoginPath(config.shell, COMMAND_NAME)) ?? undefined;
      return commandLinkStatus({ needed, env: process.env, homeDir: homedir(), resolved });
    },
    linkCommand: async () => {
      // The shim points at the managed runtime, so the durable copy must
      // exist first; durablePackageRoot is idempotent.
      await durablePackageRoot(config);
      const plan = chooseBinDir(process.env, homedir());
      writeCommandLink(plan, runtimeLayout(config.stateDir));
      return plan.onPath ? `(${plan.path})` : `(${plan.path} — ${pathHint(plan.binDir)})`;
    },
    operatingSystem: process.platform,
    userId: userInfo().uid,
    report: (message) => console.log(message),
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    now: () => Date.now(),
  };
}
