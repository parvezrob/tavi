import { execFile } from "node:child_process";
import { promisify } from "node:util";

// The one place the host runs GitHub's CLI (#79; the card badge in git.ts
// uses it too). `gh` is the person's own login on that computer — Tavi
// never holds a GitHub token. The launchd service's PATH is bare, so the
// binary is found on the login-shell PATH once (as agent kinds and
// `claude` are) and remembered; a miss is retried after a short while so
// installing gh needs no restart.

const execFileAsync = promisify(execFile);

export type GhRunner = (cwd: string, args: string[]) => Promise<{ stdout: string }>;

const GH_TIMEOUT_MS = 20_000;
const RESOLVE_RETRY_MS = 30_000;

let shell = process.env.SHELL || "/bin/sh";
let resolved: Promise<string | null> | null = null;
let resolvedAt = 0;

export function configureGh(loginShell: string): void {
  shell = loginShell;
  resolved = null;
}

// The absolute path of `gh`, or null when the login shell cannot find it.
export function ghBinary(): Promise<string | null> {
  const now = Date.now();
  if (resolved && (now - resolvedAt < RESOLVE_RETRY_MS || resolvedAt === -1)) return resolved;
  resolvedAt = now;
  resolved = new Promise((resolve) => {
    execFile(shell, ["-lc", "command -v gh"], { timeout: 10_000 }, (error, stdout) => {
      const found = String(stdout ?? "").trim().split("\n").pop()?.trim() ?? "";
      const path = !error && found.startsWith("/") ? found : null;
      // A hit is kept for good; a miss is asked again later.
      if (path) resolvedAt = -1;
      resolve(path);
    });
  });
  return resolved;
}

export async function runGh(cwd: string, args: string[]): Promise<{ stdout: string }> {
  const binary = (await ghBinary()) ?? "gh";
  const { stdout } = await execFileAsync(binary, args, {
    cwd,
    timeout: GH_TIMEOUT_MS,
    encoding: "utf8",
    maxBuffer: 4 * 1024 * 1024,
    env: { ...process.env, GH_PROMPT_DISABLED: "1", GH_NO_UPDATE_NOTIFIER: "1", NO_COLOR: "1", GH_PAGER: "cat" },
  });
  return { stdout };
}

// Why gh could not answer, as a sentence a person can act on.
export function describeGhFailure(error: unknown): string {
  const code = (error as { code?: unknown }).code;
  const stderr = String((error as { stderr?: string }).stderr ?? "").trim();
  const message = error instanceof Error ? error.message : String(error);
  const text = `${stderr}\n${message}`;
  if (code === "ENOENT" || /command not found|not installed/i.test(text)) {
    return "GitHub CLI (gh) is not installed on this computer. Install it there and run gh auth login.";
  }
  if (/gh auth login|not logged in|authentication required|HTTP 401|Bad credentials/i.test(text)) {
    return "gh on this computer is not logged in to GitHub. Run gh auth login there.";
  }
  if (/not a git repository|no git remotes|could not determine base repo|none of the git remotes|does not appear to be a git repository/i.test(text)) {
    return "This repository has no GitHub remote, so there is nothing to open a pull request on.";
  }
  if (code === "ETIMEDOUT" || /SIGTERM|timed out|Could not resolve host|connect: network is unreachable/i.test(text)) {
    return "GitHub could not be reached from this computer.";
  }
  const first = stderr.split("\n").map((line) => line.trim()).filter(Boolean)[0];
  return first ? `gh said: ${first}` : `gh could not answer: ${message}`;
}
