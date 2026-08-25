import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import type { HostConfig } from "./config.js";

// Installs Claude Code lifecycle hooks that report to the Mocha host
// (issue #22): Notification carries permission requests, and
// PostToolUse/Stop/UserPromptSubmit prove resolution. The hook command
// reads the pairing token from ~/.mocha/config.json at fire time, stays
// silent on stdout (UserPromptSubmit stdout would become model context),
// and times out fast so a down host can never stall Claude.
const HOOK_EVENTS = [
  "Notification",
  "PermissionRequest",
  "PostToolUse",
  "Stop",
  "UserPromptSubmit",
] as const;
const HOOK_MARKER = "/api/hooks/claude";

export function claudeHookCommand(config: HostConfig): string {
  const tokenScript =
    'JSON.parse(require("fs").readFileSync(process.env.HOME+"/.mocha/config.json","utf8")).token';
  return (
    `curl -s -m 3 -o /dev/null -X POST -H "Content-Type: application/json" ` +
    `-H "Authorization: Bearer $(node -p '${tokenScript}' 2>/dev/null)" ` +
    `--data-binary @- http://127.0.0.1:${config.port}${HOOK_MARKER} || true`
  );
}

export function installClaudeHooks(
  config: HostConfig,
  settingsPath = path.join(homedir(), ".claude", "settings.json"),
): { settingsPath: string; changed: boolean } {
  mkdirSync(path.dirname(settingsPath), { recursive: true });
  let settings: Record<string, unknown> = {};
  if (existsSync(settingsPath)) {
    settings = JSON.parse(readFileSync(settingsPath, "utf8")) as Record<string, unknown>;
  }

  const command = claudeHookCommand(config);
  const hooks =
    typeof settings.hooks === "object" && settings.hooks !== null
      ? (settings.hooks as Record<string, unknown>)
      : {};
  let changed = false;

  for (const event of HOOK_EVENTS) {
    const entries = Array.isArray(hooks[event]) ? (hooks[event] as unknown[]) : [];
    const withoutMocha = entries.filter((entry) => !JSON.stringify(entry).includes(HOOK_MARKER));
    const next = [...withoutMocha, { hooks: [{ type: "command", command, timeout: 5 }] }];
    if (JSON.stringify(entries) !== JSON.stringify(next)) changed = true;
    hooks[event] = next;
  }

  if (changed) {
    if (existsSync(settingsPath)) {
      copyFileSync(settingsPath, `${settingsPath}.mocha-backup`);
    }
    settings.hooks = hooks;
    writeFileSync(settingsPath, `${JSON.stringify(settings, null, 2)}\n`, "utf8");
  }
  return { settingsPath, changed };
}
