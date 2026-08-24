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

export interface AttachCommand {
  bin: string;
  args: string[];
}

// The narrow contract the server needs from a session backend. tmux is the
// only implementation today; alternative multiplexers can slot in behind it.
export interface SessionBackend {
  version(): Promise<string>;
  listSessions(): Promise<SessionInfo[]>;
  getSession(id: string): Promise<SessionInfo | undefined>;
  createSession(input: CreateSessionInput): Promise<SessionInfo>;
  killSession(id: string): Promise<void>;
  listWorkspaces(): Promise<WorkspaceInfo[]>;
  attachCommand(id: string): AttachCommand;
}

export type ClientTerminalMessage =
  | { type: "input"; data: string }
  | { type: "resize"; cols: number; rows: number }
  | { type: "ping"; id: string };

export type ServerTerminalMessage =
  | { type: "ready" }
  | { type: "output"; data: string }
  | { type: "pong"; id: string }
  | { type: "exit"; code: number; signal?: number }
  | { type: "error"; message: string };
