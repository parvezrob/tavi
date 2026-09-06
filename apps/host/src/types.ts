export interface HostInfo {
  name: string;
  platform: NodeJS.Platform;
  arch: string;
  version: string;
}

export interface WorkspaceInfo {
  name: string;
  path: string;
  git: boolean;
}

// How to attach a pty to an agent pane: the herdr CLI and its arguments.
export interface AttachCommand {
  bin: string;
  args: string[];
}

export type AgentStatus = "idle" | "working" | "blocked" | "done" | "unknown";

export interface HerdrAgentInfo {
  id: string;
  agent: string;
  status: AgentStatus;
  cwd: string;
  title: string;
  workspaceId: string;
  tabId: string;
  // The tab's label as herdr reports it (#55). Users rename tabs to name
  // the task; the phone decides which labels are user-meaningful.
  tabLabel?: string | undefined;
  focused: boolean;
  revision: number;
  // Who asserted `status`: herdr's screen detection, or the agent's own
  // lifecycle hooks (issue #22) — the more direct authority wins.
  authority: "herdr" | "claude-hook";
  // The agent's own session identifier when herdr knows it (for claude,
  // the Claude Code session UUID) — the join key for hook events.
  sessionRef?: string | undefined;
  // What herdr's own screen detection says is running in the pane, when it
  // differs from `agent` (#66): a Terminal Tavi reported as "shell" that
  // now shows Claude's prompt has agent "shell" and detectedAgent "claude"
  // until Tavi hands the pane back to herdr's detection.
  detectedAgent?: string | undefined;
}

export interface HerdrAgentsResult {
  provider: "herdr";
  available: boolean;
  protocol?: number;
  reason?: string;
  agents: HerdrAgentInfo[];
}

export type ClientTerminalMessage =
  | { type: "input"; data: string }
  | { type: "resize"; cols: number; rows: number }
  | { type: "ping"; id: string };

export type ServerTerminalMessage =
  | { type: "ready"; stream?: string; offset?: number; resumed?: boolean }
  | { type: "output"; data: string }
  | { type: "pong"; id: string }
  | { type: "exit"; code: number; signal?: number }
  // Set only for a takeover; the close that follows can be lost or delayed.
  | { type: "error"; message: string; code?: "superseded" };
