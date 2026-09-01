import { execFile } from "node:child_process";

// Not an agent herdr launches: a plain shell in the chosen folder, which
// Tavi then *reports* to herdr as an agent so it lists and attaches like
// one (herdr refuses to attach an unreported pane). Always available — it
// is the pane's own shell.
export const SHELL_KIND = "shell";

// Every agent herdr can launch (`herdr agent start --kind`, verified against
// herdr 0.7.5). The kind doubles as the executable name, which is how both
// herdr and this file decide whether one is installed. Labels are the
// product names people recognise; anything herdr adds later still works —
// it just shows its kind verbatim until a label is added here.
export const AGENT_KINDS: ReadonlyArray<{ kind: string; label: string }> = [
  { kind: SHELL_KIND, label: "Terminal" },
  { kind: "claude", label: "Claude Code" },
  { kind: "codex", label: "Codex" },
  { kind: "gemini", label: "Gemini CLI" },
  { kind: "opencode", label: "OpenCode" },
  { kind: "copilot", label: "GitHub Copilot" },
  { kind: "cursor", label: "Cursor" },
  { kind: "amp", label: "Amp" },
  { kind: "droid", label: "Droid" },
  { kind: "kimi", label: "Kimi" },
  { kind: "kiro", label: "Kiro" },
  { kind: "grok", label: "Grok" },
  { kind: "cline", label: "Cline" },
  { kind: "devin", label: "Devin" },
  { kind: "hermes", label: "Hermes" },
  { kind: "kilo", label: "Kilo" },
  { kind: "pi", label: "Pi" },
  { kind: "agy", label: "Agy" },
  { kind: "omp", label: "Omp" },
  { kind: "mastracode", label: "Mastra Code" },
  { kind: "qodercli", label: "Qoder CLI" },
  { kind: "maki", label: "Maki" },
];

export const AGENT_KIND_NAMES: readonly string[] = AGENT_KINDS.map((entry) => entry.kind);

export interface AgentKindAvailability {
  kind: string;
  label: string;
  // The executable resolves on this Mac's login-shell PATH — the PATH the
  // agent's pane will actually get. Offering an uninstalled kind would
  // only fail thirty seconds later inside herdr.
  installed: boolean;
}

// Only launched-once-per-cache-window: resolving via a login shell costs a
// shell startup, and the picker is opened far more often than PATH changes.
const CACHE_MILLISECONDS = 60_000;

export interface AgentKindDetectorOptions {
  shell: string;
  runShell?: (shell: string, script: string) => Promise<string>;
  now?: () => number;
}

export class AgentKindDetector {
  private cached: { at: number; kinds: AgentKindAvailability[] } | undefined;

  constructor(private readonly options: AgentKindDetectorOptions) {}

  async list(): Promise<AgentKindAvailability[]> {
    const now = this.options.now?.() ?? Date.now();
    if (this.cached && now - this.cached.at < CACHE_MILLISECONDS) return this.cached.kinds;

    const installed = await this.detect();
    installed.add(SHELL_KIND);
    const kinds = AGENT_KINDS.map((entry) => ({ ...entry, installed: installed.has(entry.kind) }));
    this.cached = { at: now, kinds };
    return kinds;
  }

  // One shell, one line per found executable. The launchd service runs
  // with a bare PATH, so this asks the user's login shell (`-l`) the way
  // herdr's own pane would resolve the command — without that, anything in
  // ~/.local/bin or a version manager would read as missing.
  private async detect(): Promise<Set<string>> {
    const script = AGENT_KIND_NAMES.filter((kind) => kind !== SHELL_KIND)
      .map((kind) => `command -v ${kind} >/dev/null 2>&1 && echo ${kind}`)
      .join("; ");
    try {
      const output = await (this.options.runShell ?? runLoginShell)(this.options.shell, script);
      return new Set(
        output
          .split("\n")
          .map((line) => line.trim())
          .filter((line) => AGENT_KIND_NAMES.includes(line)),
      );
    } catch {
      // No login shell to ask means no knowledge — nothing is claimed
      // installed, and the picker says so instead of guessing.
      return new Set();
    }
  }
}

function runLoginShell(shell: string, script: string): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(shell, ["-lc", script], { timeout: 10_000 }, (error, stdout) => {
      // A non-zero exit is normal here: the last `command -v` in the chain
      // fails whenever that kind is absent. Only a spawn failure matters.
      if (error && typeof stdout !== "string") reject(error);
      else resolve(stdout ?? "");
    });
  });
}
