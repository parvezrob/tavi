import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { HostConfig } from "./config.js";

// Installs Claude Code lifecycle hooks that report to the Tavi host
// (issue #22): Notification carries permission requests, and
// PostToolUse/Stop/UserPromptSubmit prove resolution. The hook command is a
// relay script so the pairing token never appears in another process's argv
// (issue #32); the relay reads it from ~/.tavi/config.json at fire time,
// stays silent on stdout (UserPromptSubmit stdout would become model
// context), and times out fast so a down host can never stall Claude.
const HOOK_EVENTS = ["Notification", "PermissionRequest", "PostToolUse", "Stop", "UserPromptSubmit"] as const;
// Both markers identify Tavi-owned entries: the relay filename for current
// installs, the endpoint path for pre-relay curl commands being replaced.
const HOOK_MARKERS = ["claude-hook-relay.js", "/api/hooks/claude"];

export function claudeHookCommand(config: HostConfig, relayPath = defaultRelayPath()): string {
  return `node '${relayPath}' ${config.port} || true`;
}

function defaultRelayPath(): string {
  return path.join(path.dirname(fileURLToPath(import.meta.url)), "claude-hook-relay.js");
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
    typeof settings.hooks === "object" && settings.hooks !== null ? (settings.hooks as Record<string, unknown>) : {};
  let changed = false;

  for (const event of HOOK_EVENTS) {
    const entries = Array.isArray(hooks[event]) ? (hooks[event] as unknown[]) : [];
    const withoutTavi = entries.filter(
      (entry) => !HOOK_MARKERS.some((marker) => JSON.stringify(entry).includes(marker)),
    );
    const next = [...withoutTavi, { hooks: [{ type: "command", command, timeout: 5 }] }];
    if (JSON.stringify(entries) !== JSON.stringify(next)) changed = true;
    hooks[event] = next;
  }

  if (changed) {
    if (existsSync(settingsPath)) {
      copyFileSync(settingsPath, `${settingsPath}.tavi-backup`);
    }
    settings.hooks = hooks;
    writeFileSync(settingsPath, `${JSON.stringify(settings, null, 2)}\n`, "utf8");
  }
  return { settingsPath, changed };
}

/** Removes Tavi's hook entries and nothing else; true when the file changed. */
export function removeClaudeHooks(settingsPath = path.join(homedir(), ".claude", "settings.json")): boolean {
  if (!existsSync(settingsPath)) return false;
  const settings = JSON.parse(readFileSync(settingsPath, "utf8")) as Record<string, unknown>;
  const hooks =
    typeof settings.hooks === "object" && settings.hooks !== null
      ? (settings.hooks as Record<string, unknown>)
      : undefined;
  if (!hooks) return false;
  let changed = false;
  for (const event of Object.keys(hooks)) {
    const entries = Array.isArray(hooks[event]) ? (hooks[event] as unknown[]) : [];
    const kept = entries.filter((entry) => !HOOK_MARKERS.some((marker) => JSON.stringify(entry).includes(marker)));
    if (kept.length !== entries.length) changed = true;
    if (kept.length === 0) delete hooks[event];
    else hooks[event] = kept;
  }
  if (changed) writeFileSync(settingsPath, `${JSON.stringify(settings, null, 2)}\n`, "utf8");
  return changed;
}
