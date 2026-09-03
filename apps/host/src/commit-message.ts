import { spawn } from "node:child_process";
import { looksLikeASecret } from "./files.js";
import { describeGitError, git } from "./git-exec.js";
import { resolveOnLoginPath } from "./login-shell.js";
import { stagedPaths } from "./source-control.js";

// Source Control — the written commit message (#77): the one place this
// host asks a model for anything. Split out of source-control.ts in #98 —
// staging and committing are git; this is a subprocess, a prompt, and a
// timeout, with its own reasons to change.

export type MessageResult = { ok: true; message: string } | { ok: false; status: 409 | 503; error: string };

export interface MessageWriterDeps {
  shell: string;
  // Runs the model with a prompt and stdin, returns its text. Injectable so
  // tests need no `claude`.
  runClaude?: (prompt: string, input: string) => Promise<string>;
}

const MAX_DIFF_FOR_MESSAGE = 200 * 1024;
const CLAUDE_TIMEOUT_MS = 45_000;
const MESSAGE_PROMPT =
  "Write a git commit message for the staged diff on stdin: one line in conventional-commit form " +
  "(type(scope): summary), at most 72 characters, imperative, no quotes, no trailing period, " +
  "then nothing else. Output only the message.";

// A one-line conventional message for the staged set, written by the
// `claude` CLI on this computer — the same login the terminals use — from
// the staged diff with secret-looking files left out by name. 409 when
// nothing is staged, 503 when git cannot say what is staged, or when claude
// is missing or says nothing.
export async function writeCommitMessage(worktreePath: string, deps: MessageWriterDeps): Promise<MessageResult> {
  const stagedFiles = await stagedPaths(worktreePath);
  if (!stagedFiles.ok) return stagedFiles;
  const staged = stagedFiles.paths;
  if (staged.length === 0) return { ok: false, status: 409, error: "Nothing is staged. Stage a file first." };
  const shown = staged.filter((file) => !looksLikeASecret(file));
  let diff = "";
  if (shown.length > 0) {
    try {
      diff = (await git(worktreePath, ["diff", "--cached", "--", ...shown], MAX_DIFF_FOR_MESSAGE + 1)).stdout.slice(
        0,
        MAX_DIFF_FOR_MESSAGE,
      );
    } catch (error) {
      return { ok: false, status: 503, error: `git could not read the staged diff: ${describeGitError(error)}` };
    }
  }
  const header = `Staged files: ${staged.join(", ")}\n\n`;
  try {
    const run = deps.runClaude ?? ((prompt, input) => runClaudeCli(deps.shell, prompt, input));
    const text = (await run(MESSAGE_PROMPT, header + diff)).trim().split("\n")[0]?.trim() ?? "";
    if (!text) return { ok: false, status: 503, error: "Claude did not write a message. Type one instead." };
    return { ok: true, message: text.slice(0, 200) };
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    if (/not installed|ENOENT|command not found/i.test(reason)) {
      return {
        ok: false,
        status: 503,
        error: "Claude Code is not installed on this computer, so it cannot write the message. Type one instead.",
      };
    }
    return { ok: false, status: 503, error: `Claude could not write a message: ${reason}` };
  }
}

// `claude -p <prompt>` with the diff on stdin, resolved on the login-shell
// PATH the way agent kinds are (the launchd service's own PATH is bare).
async function runClaudeCli(shell: string, prompt: string, input: string): Promise<string> {
  const binary = await resolveOnLoginPath(shell, "claude");
  if (!binary) throw new Error("claude is not installed");
  return new Promise((resolve, reject) => {
    const child = spawn(binary, ["-p", prompt, "--output-format", "text"], {
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1" },
    });
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    const timer = setTimeout(() => child.kill(), CLAUDE_TIMEOUT_MS);
    child.stdout.on("data", (chunk: Buffer) => out.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => err.push(chunk));
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code === 0) resolve(Buffer.concat(out).toString("utf8"));
      else reject(new Error(Buffer.concat(err).toString("utf8").trim() || `claude exited with ${code}`));
    });
    child.stdin.on("error", () => undefined);
    child.stdin.end(input);
  });
}
