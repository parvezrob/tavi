import { execFile } from "node:child_process";

// Asking the person's login shell where a command is (#97). The launchd
// service runs with a bare PATH, so `which` would miss anything in
// ~/.local/bin or a version manager — the same PATH an agent's own pane
// gets is only reachable through `$SHELL -lc`. Four callers had a copy of
// this: gh, tailscale, the Claude CLI, and the agent-kind catalog. Each
// still owns whether and for how long it remembers the answer.

const SHELL_TIMEOUT_MS = 10_000;

// One script, its stdout. Rejects only when the shell itself cannot be
// started: a non-zero exit is normal here, because `command -v` fails for
// every command that is absent.
export function runLoginShell(shell: string, script: string): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(shell, ["-lc", script], { timeout: SHELL_TIMEOUT_MS }, (error, stdout) => {
      if (error && typeof stdout !== "string") reject(error);
      else resolve(stdout ?? "");
    });
  });
}

// The absolute path of one command, or null when the login shell cannot
// find it — which a non-zero exit is exactly how it says.
export function resolveOnLoginPath(shell: string, name: string): Promise<string | null> {
  // The name is ours, never the phone's — and it is still checked before it
  // goes anywhere near a shell line.
  if (!/^[a-z][a-z0-9-]*$/.test(name)) return Promise.resolve(null);
  return new Promise((resolve) => {
    execFile(shell, ["-lc", `command -v ${name}`], { timeout: SHELL_TIMEOUT_MS }, (error, stdout) => {
      const found =
        String(stdout ?? "")
          .trim()
          .split("\n")
          .pop()
          ?.trim() ?? "";
      resolve(!error && found.startsWith("/") ? found : null);
    });
  });
}
