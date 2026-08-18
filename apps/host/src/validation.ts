import path from "node:path";
import type { AgentKind, CreateSessionInput } from "./types.js";

const AGENTS = new Set<AgentKind>(["shell", "codex", "claude", "custom"]);

export class InputError extends Error {}

export function parseCreateSession(value: unknown): CreateSessionInput {
  if (!value || typeof value !== "object") throw new InputError("Expected a JSON object.");
  const body = value as Record<string, unknown>;

  const name = typeof body.name === "string" ? body.name.trim() : "";
  const cwd = typeof body.cwd === "string" ? body.cwd.trim() : "";
  const agent = body.agent as AgentKind;
  const command = typeof body.command === "string" ? body.command.trim() : undefined;

  if (!name || name.length > 80) throw new InputError("Name must be between 1 and 80 characters.");
  if (!cwd || !path.isAbsolute(cwd)) throw new InputError("Working directory must be an absolute path.");
  if (!AGENTS.has(agent)) throw new InputError("Unknown agent type.");
  if (agent === "custom" && !command) throw new InputError("A custom command is required.");
  if (command && command.length > 4_096) throw new InputError("Command is too long.");

  return { name, cwd, agent, ...(command ? { command } : {}) };
}

export function safeSessionId(value: string): string {
  const decoded = decodeURIComponent(value);
  if (!/^[A-Za-z0-9_.:-]{1,128}$/.test(decoded)) throw new InputError("Invalid session id.");
  return decoded;
}
