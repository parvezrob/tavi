import { accessSync, constants, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { type RuntimeLayout } from "./runtime.js";

// The `tavi` command for a host installed by `npx tavi-host pair` (#64).
// The managed runtime lives under ~/.tavi/runtime and nothing used to put a
// command on PATH, so every documented `tavi doctor` / `tavi update` failed
// with "command not found" — and the natural repair, `npx tavi update`,
// runs a stranger's package that owns the bare name on npm. `pair` now
// writes a tiny shell shim that execs whatever `current` points at, so it
// keeps working across self-updates, and `uninstall` removes it.

export const COMMAND_NAME = "tavi";
export const COMMAND_LINK_MARKER = "# tavi command — written by tavi-host; runs the copy the background service runs.";

export interface CommandLinkPlan {
  binDir: string;
  path: string;
  // Whether binDir is already on the person's PATH; when it is not, the ✓
  // line says what to add — once, in one sentence.
  onPath: boolean;
}

export interface CommandLinkStatus {
  // False for a checkout or a global npm install: those already have (or
  // deliberately do not want) a command; only the managed runtime needs one.
  needed: boolean;
  ok: boolean;
  detail: string;
  fix?: string;
}

// Prefer a directory that is already on PATH and writable — Homebrew's bin
// on a Mac, /usr/local/bin — so the command works in the very next shell
// without anyone editing a profile. Otherwise ~/.local/bin, which most Linux
// shells add when it exists, and say so if this one does not.
export function chooseBinDir(env: NodeJS.ProcessEnv, homeDir: string): CommandLinkPlan {
  const onPath = (env.PATH ?? "").split(path.delimiter).filter(Boolean).map((entry) => path.resolve(entry));
  for (const candidate of ["/opt/homebrew/bin", "/usr/local/bin"]) {
    if (onPath.includes(candidate) && writable(candidate)) {
      return { binDir: candidate, path: path.join(candidate, COMMAND_NAME), onPath: true };
    }
  }
  const local = path.join(homeDir, ".local", "bin");
  return { binDir: local, path: path.join(local, COMMAND_NAME), onPath: onPath.includes(path.resolve(local)) };
}

function writable(directory: string): boolean {
  try {
    accessSync(directory, constants.W_OK);
    return true;
  } catch {
    return false;
  }
}

// `exec` so signals and exit codes pass straight through; `/usr/bin/env
// node` so an nvm or Homebrew node move does not strand the shim.
export function commandLinkSource(layout: RuntimeLayout): string {
  const entry = path.join(layout.currentLink, "node_modules", "tavi-host", "dist", "index.js");
  return `#!/bin/sh\n${COMMAND_LINK_MARKER}\nexec /usr/bin/env node "${entry}" "$@"\n`;
}

export function writeCommandLink(plan: CommandLinkPlan, layout: RuntimeLayout): string {
  mkdirSync(plan.binDir, { recursive: true });
  writeFileSync(plan.path, commandLinkSource(layout), { encoding: "utf8", mode: 0o755 });
  return plan.path;
}

export function isOurCommandLink(file: string): boolean {
  try {
    return readFileSync(file, "utf8").split("\n").slice(0, 3).includes(COMMAND_LINK_MARKER);
  } catch {
    return false;
  }
}

// Where the shim may live on this machine, for status and removal.
export function commandLinkCandidates(homeDir: string): string[] {
  return ["/opt/homebrew/bin", "/usr/local/bin", path.join(homeDir, ".local", "bin")].map((dir) => path.join(dir, COMMAND_NAME));
}

export function commandLinkStatus(options: {
  needed: boolean;
  env: NodeJS.ProcessEnv;
  homeDir: string;
  // What `which tavi` finds, if anything.
  resolved: string | undefined;
}): CommandLinkStatus {
  if (!options.needed) return { needed: false, ok: true, detail: "not needed for this install" };
  if (options.resolved) {
    return { needed: true, ok: true, detail: `\`${COMMAND_NAME}\` is ${options.resolved}` };
  }
  const existing = commandLinkCandidates(options.homeDir).find((file) => existsSync(file) && isOurCommandLink(file));
  if (existing) {
    const dir = path.dirname(existing);
    return {
      needed: true,
      ok: false,
      detail: `\`${COMMAND_NAME}\` is installed at ${existing} but ${dir} is not on your PATH.`,
      fix: pathHint(dir),
    };
  }
  return { needed: true, ok: false, detail: `The \`${COMMAND_NAME}\` command is not set up.`, fix: "Run `npx tavi-host pair` again; it adds the command." };
}

export function pathHint(dir: string): string {
  return `Add ${dir} to your PATH — for zsh: echo 'export PATH="${dir}:$PATH"' >> ~/.zshrc, then open a new terminal.`;
}

// Removes every shim that is ours; a `tavi` that is someone else's stays.
export function removeCommandLink(homeDir: string): string | undefined {
  const removed = commandLinkCandidates(homeDir).filter((file) => existsSync(file) && isOurCommandLink(file));
  for (const file of removed) rmSync(file, { force: true });
  return removed.length === 0 ? undefined : removed.join(", ");
}
