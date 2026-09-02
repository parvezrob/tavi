import { execFile } from "node:child_process";
import { promisify } from "node:util";

// The one `git` invocation helper, shared by every read (and, from #59 on,
// worktree) route: execFile (no shell), a timeout, and the exit-code
// tolerance a few git subcommands need (`diff` exits 1 on a difference).
// Extracted from changes.ts when git.ts became the second consumer.

const execFileAsync = promisify(execFile);
const GIT_TIMEOUT_MS = 8_000;

export async function git(
  cwd: string,
  args: string[],
  maxBuffer = 4 * 1024 * 1024,
  okExitCodes: number[] = [0],
  // Only network commands (#78 push) need more than the local budget.
  timeoutMs = GIT_TIMEOUT_MS,
): Promise<{ stdout: string }> {
  try {
    const { stdout } = await execFileAsync("git", ["-C", cwd, ...args], {
      timeout: timeoutMs,
      maxBuffer,
      encoding: "utf8",
      env: {
        ...process.env,
        GIT_OPTIONAL_LOCKS: "0",
        GIT_TERMINAL_PROMPT: "0",
        // A push over SSH must fail, never wait on a host-key or passphrase
        // prompt nobody can see: the service has no terminal.
        GIT_SSH_COMMAND: process.env.GIT_SSH_COMMAND ?? "ssh -o BatchMode=yes -o ConnectTimeout=15",
      },
    });
    return { stdout };
  } catch (error) {
    const code = (error as { code?: unknown }).code;
    const stdout = (error as { stdout?: string }).stdout;
    if (typeof code === "number" && okExitCodes.includes(code) && typeof stdout === "string") return { stdout };
    // Output beyond maxBuffer: what git managed to print is still the
    // start of the answer, and the caller marks it truncated.
    if (code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER" && typeof stdout === "string") return { stdout };
    throw error;
  }
}

export function describeGitError(error: unknown): string {
  const stderr = (error as { stderr?: string }).stderr;
  if (typeof stderr === "string" && stderr.trim()) return stderr.trim();
  return error instanceof Error ? error.message : String(error);
}
