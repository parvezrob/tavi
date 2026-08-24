import { execFile, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { access, readdir, stat } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import type {
  AgentKind,
  AttachCommand,
  CreateSessionInput,
  SessionBackend,
  SessionInfo,
  WorkspaceInfo,
} from "./types.js";

const execFileAsync = promisify(execFile);
const FIELD_SEPARATOR = "\u001f";
const MANAGED_SESSION_PREFIX = "mocha-";
const LEGACY_SESSION_PREFIX = "deck-";
const DEFAULT_SOCKET_NAME = "mocha";

export interface TmuxOptions {
  bin: string;
  shell: string;
  roots: string[];
  socketName?: string;
  execute?: (args: string[]) => Promise<string>;
}

export class TmuxService implements SessionBackend {
  constructor(private readonly options: TmuxOptions) {}

  async version(): Promise<string> {
    return (await this.run(["-V"])).trim();
  }

  async listSessions(): Promise<SessionInfo[]> {
    const format = [
      "#{session_name}",
      "#{session_created}",
      "#{session_activity}",
      "#{session_attached}",
      "#{session_windows}",
      "#{pane_current_path}",
      "#{pane_start_command}",
    ].join(FIELD_SEPARATOR);

    try {
      const stdout = await this.run(["list-sessions", "-F", format]);
      return stdout
        .trim()
        .split("\n")
        .filter(Boolean)
        .map((line) => this.parseSession(line))
        .sort((a, b) => b.activeAt - a.activeAt);
    } catch (error) {
      if (this.isNoServerError(error)) return [];
      throw error;
    }
  }

  async getSession(id: string): Promise<SessionInfo | undefined> {
    return (await this.listSessions()).find((session) => session.id === id);
  }

  async createSession(input: CreateSessionInput): Promise<SessionInfo> {
    await this.assertDirectory(input.cwd);
    const id = `${MANAGED_SESSION_PREFIX}${this.slug(input.name)}-${randomBytes(3).toString("hex")}`;
    const command = this.commandFor(input);
    const args = [
      "new-session",
      "-d",
      "-s",
      id,
      "-c",
      input.cwd,
      "-x",
      "120",
      "-y",
      "36",
    ];
    if (command) args.push(command);

    await this.run(args);
    await this.makeSessionResponsive(id);
    const created = await this.getSession(id);
    if (!created) throw new Error("tmux created the session, but it could not be read back.");
    return created;
  }

  async killSession(id: string): Promise<void> {
    await this.run(["kill-session", "-t", id]);
  }

  async listWorkspaces(): Promise<WorkspaceInfo[]> {
    const workspaces = new Map<string, WorkspaceInfo>();

    for (const root of this.options.roots) {
      try {
        const rootStat = await stat(root);
        if (!rootStat.isDirectory()) continue;
        workspaces.set(root, { name: path.basename(root), path: root, git: await this.isGitRoot(root) });

        const entries = await readdir(root, { withFileTypes: true });
        for (const entry of entries) {
          if (!entry.isDirectory() || entry.name.startsWith(".")) continue;
          const candidate = path.join(root, entry.name);
          workspaces.set(candidate, {
            name: entry.name,
            path: candidate,
            git: await this.isGitRoot(candidate),
          });
          if (workspaces.size >= 160) break;
        }
      } catch {
        // Roots can be removable drives or temporarily unavailable mounts.
      }
    }

    return [...workspaces.values()].sort((a, b) => {
      if (a.git !== b.git) return a.git ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
  }

  attachCommand(id: string): AttachCommand {
    return {
      bin: this.options.bin,
      args: [...this.socketArgs(), "attach-session", "-t", id],
    };
  }

  // tmux defaults are tuned for interactive desktop use: a 500ms escape-key
  // delay and a visible status bar. Mocha treats tmux as an invisible
  // backbone, so managed sessions get low-latency keys and no tmux chrome.
  // Mouse mode makes touch scrolling reach tmux as wheel events (native
  // copy-mode scrollback) instead of degrading into arrow-key input.
  private async makeSessionResponsive(id: string): Promise<void> {
    await this.run(["set-option", "-s", "escape-time", "10"]);
    await this.run(["set-option", "-s", "focus-events", "on"]);
    await this.run(["set-option", "-t", id, "status", "off"]);
    await this.run(["set-option", "-t", id, "mouse", "on"]);
  }

  private socketArgs(): string[] {
    return ["-L", this.options.socketName || DEFAULT_SOCKET_NAME];
  }

  private parseSession(line: string): SessionInfo {
    const [id = "", created = "0", active = "0", attached = "0", windows = "0", cwd = "", command = ""] =
      line.split(FIELD_SEPARATOR);
    return {
      id,
      name: this.displayName(id),
      createdAt: Number(created) * 1_000,
      activeAt: Number(active) * 1_000,
      attached: Number(attached),
      windows: Number(windows),
      cwd,
      command,
      managed: this.isManagedSession(id),
      agent: this.inferAgent(command),
    };
  }

  private commandFor(input: CreateSessionInput): string | undefined {
    if (input.command) return input.command;
    switch (input.agent) {
      case "codex":
        return "codex";
      case "claude":
        return "claude";
      case "shell":
        return undefined;
      case "custom":
        return undefined;
    }
  }

  private inferAgent(command: string): AgentKind {
    const normalized = command.toLowerCase();
    if (/(^|\s|\/)codex(\s|$)/.test(normalized)) return "codex";
    if (/(^|\s|\/)claude(\s|$)/.test(normalized)) return "claude";
    if (!command || command.includes(this.options.shell) || /(^|\/)(zsh|bash|fish|sh)(\s|$)/.test(normalized)) {
      return "shell";
    }
    return "custom";
  }

  private displayName(id: string): string {
    const prefix = [MANAGED_SESSION_PREFIX, LEGACY_SESSION_PREFIX].find((candidate) => id.startsWith(candidate));
    if (!prefix) return id;
    return id.slice(prefix.length).replace(/-[a-f0-9]{6}$/, "").replaceAll("-", " ");
  }

  private isManagedSession(id: string): boolean {
    return id.startsWith(MANAGED_SESSION_PREFIX) || id.startsWith(LEGACY_SESSION_PREFIX);
  }

  private slug(value: string): string {
    const slug = value
      .toLowerCase()
      .normalize("NFKD")
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-|-$/g, "")
      .slice(0, 48);
    return slug || "session";
  }

  private async assertDirectory(directory: string): Promise<void> {
    const info = await stat(directory).catch(() => undefined);
    if (!info?.isDirectory()) throw new Error(`Working directory does not exist: ${directory}`);
    await access(directory);
  }

  private async isGitRoot(directory: string): Promise<boolean> {
    return stat(path.join(directory, ".git"))
      .then(() => true)
      .catch(() => false);
  }

  private isNoServerError(error: unknown): boolean {
    if (!error || typeof error !== "object") return false;
    const candidate = error as { stderr?: string; code?: number };
    return candidate.code === 1 && /no server running|failed to connect|no sessions/i.test(candidate.stderr || "");
  }

  private async run(args: string[]): Promise<string> {
    if (this.options.execute) return this.options.execute(args);
    const env = { ...process.env };
    delete env.npm_config_prefix;
    delete env.NPM_CONFIG_PREFIX;
    const { stdout } = await execFileAsync(this.options.bin, [...this.socketArgs(), ...args], { env });
    return stdout;
  }
}

export function startTmuxForSmokeTest(bin: string, name: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, ["new-session", "-d", "-s", name]);
    child.once("exit", (code) => (code === 0 ? resolve() : reject(new Error(`tmux exited ${code}`))));
    child.once("error", reject);
  });
}
