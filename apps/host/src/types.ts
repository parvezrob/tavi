export type AgentKind = "shell" | "codex" | "claude" | "custom";

export interface HostInfo {
  name: string;
  platform: NodeJS.Platform;
  arch: string;
  version: string;
  tmuxVersion: string;
}

export interface SessionInfo {
  id: string;
  name: string;
  createdAt: number;
  activeAt: number;
  attached: number;
  windows: number;
  cwd: string;
  command: string;
  managed: boolean;
  agent: AgentKind;
}

export interface WorkspaceInfo {
  name: string;
  path: string;
  git: boolean;
}

export interface CreateSessionInput {
  name: string;
  cwd: string;
  agent: AgentKind;
  command?: string;
}

export type ClientTerminalMessage =
  | { type: "input"; data: string }
  | { type: "resize"; cols: number; rows: number };

export type ServerTerminalMessage =
  | { type: "ready" }
  | { type: "output"; data: string }
  | { type: "exit"; code: number; signal?: number }
  | { type: "error"; message: string };
