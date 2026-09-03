import { execFile } from "node:child_process";
import { existsSync, readFileSync, rmSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import type { HostConfig } from "./config.js";
import {
  isManagedRuntime,
  packageRootFor,
  runtimeLayout,
  switchCurrent,
  versionPrefix,
  writeLauncher,
} from "./runtime.js";

// Where the copy of Tavi that the background service runs lives (#47, #64).
// Split out of bootstrap.ts in #98: the install checklist asks for this, and
// so do `install-service` and the `tavi` shim, but the npm layout has its own
// reasons to change.

const execFileAsync = promisify(execFile);
const PACKAGE_NAME = "tavi-host";

// `npx tavi-host` runs from npm's ephemeral cache, which is no place for a
// login service to live: the cache gets pruned and a later `npx` of a newer
// version would not touch the service. So the first pair installs a durable
// copy under ~/.tavi/runtime/versions/<version>, points `current` at it, and
// the service runs it through the launcher — which is also what lets the
// host update itself afterwards (src/updater.ts). A git checkout or
// `npm i -g` is already durable and is used in place.
export async function durablePackageRoot(
  config: HostConfig,
  options: {
    packageRoot?: string;
    execute?: (command: string, args: string[]) => Promise<string>;
    report?: (message: string) => void;
    env?: NodeJS.ProcessEnv;
  } = {},
): Promise<string> {
  const packageRoot = options.packageRoot ?? currentPackageRoot();
  const env = options.env ?? process.env;
  if (!isEphemeral(packageRoot, env) && !isManagedRuntime(packageRoot, config.stateDir)) return packageRoot;

  const version = readVersion(packageRoot);
  if (!/^\d+\.\d+\.\d+/.test(version)) throw new Error(`Cannot read Tavi's version from ${packageRoot}/package.json.`);
  const layout = runtimeLayout(config.stateDir);
  const target = packageRootFor(layout, version);
  if (!(existsSync(target) && readVersion(target) === version)) {
    const spec = env.TAVI_PACKAGE_SPEC ?? `${PACKAGE_NAME}@${version}`;
    const report = options.report ?? ((message: string) => console.log(message));
    report("Keeping a permanent copy of Tavi on this computer (one moment)…");
    const execute =
      options.execute ??
      (async (command: string, args: string[]) => (await execFileAsync(command, args, { timeout: 180_000 })).stdout);
    await execute("npm", [
      "install",
      "--prefix",
      versionPrefix(layout, version),
      "--no-audit",
      "--no-fund",
      "--loglevel=error",
      spec,
    ]);
    if (!existsSync(path.join(target, "dist", "index.js"))) {
      throw new Error(`npm reported success but ${target} has no dist/index.js.`);
    }
  }
  switchCurrent(layout, version);
  writeLauncher(layout);
  // Layout before 0.1.6 put the copy straight under runtime/; it is dead weight now.
  for (const stale of ["node_modules", "package.json", "package-lock.json"]) {
    rmSync(path.join(layout.root, stale), { recursive: true, force: true });
  }
  return target;
}

/** The managed runtime runs through its launcher (rollback, self-update); anything else runs dist/index.js directly. */
export function serviceEntrypoint(config: HostConfig, packageRoot: string): string {
  return isManagedRuntime(packageRoot, config.stateDir)
    ? runtimeLayout(config.stateDir).launcher
    : path.join(packageRoot, "dist", "index.js");
}

export function isEphemeral(packageRoot: string, env: NodeJS.ProcessEnv): boolean {
  return packageRoot.split(path.sep).includes("_npx") || env.npm_command === "exec";
}

export function currentPackageRoot(): string {
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
}

function readVersion(packageRoot: string): string {
  try {
    return (
      (JSON.parse(readFileSync(path.join(packageRoot, "package.json"), "utf8")) as { version?: string }).version ?? ""
    );
  } catch {
    // No readable package.json means no version to install from; the caller
    // says so by name rather than installing something arbitrary.
    return "";
  }
}
