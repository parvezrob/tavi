import { randomBytes } from "node:crypto";
import { createConnection } from "node:net";
import { parsePermissionDialog, type PermissionDialog } from "./dialog.js";
import type { AgentStatus, AttachCommand, HerdrAgentInfo, HerdrAgentsResult } from "./types.js";

// Verified against herdr 0.7.5. The socket speaks newline-delimited JSON:
// {id, method, params} -> {id, result}. Gate on the protocol number so an
// incompatible herdr degrades to "unavailable" instead of mis-parsed state.
const SUPPORTED_PROTOCOL = 17;
const REQUEST_TIMEOUT_MILLISECONDS = 2_000;
// Enough lines to always capture a dialog's option list plus its footer.
const DIALOG_READ_LINES = 40;
const AGENT_STATUSES: readonly AgentStatus[] = ["idle", "working", "blocked", "done", "unknown"];

export interface HerdrOptions {
  socketPath: string;
  bin?: string;
  requestTimeoutMilliseconds?: number;
  promptSettleMilliseconds?: number;
}

export type HerdrAgentLookup =
  | { available: true; agent?: HerdrAgentInfo }
  | { available: false; reason: string };

export type HerdrPreviewResult =
  | { available: true; preview: string }
  | { available: false; reason: string };

export type HerdrPromptResult = { submitted: true } | { submitted: false; reason: string };

export type DialogDecision = "approve" | "deny";

export type HerdrDialogResult =
  | { present: true; dialog: PermissionDialog }
  | { present: false }
  | { available: false; reason: string };

export type HerdrDecisionResult =
  | { decided: true; sent: string }
  // The dialog we were told about is no longer on screen — never fire a key
  // at whatever replaced it. The caller surfaces this so a stale card can't
  // answer a prompt that already resolved.
  | { decided: false; reason: string; stale?: boolean };

export interface HerdrTabRequest {
  agent?: string | undefined;
  cwd?: string | undefined;
  label?: string | undefined;
}

export type HerdrTabResult =
  | { created: true; paneId: string; tabId: string }
  | { created: false; reason: string };

export interface HerdrTreeTab {
  tabId: string;
  label: string;
  focused: boolean;
  agents: HerdrAgentInfo[];
}

export interface HerdrTreeWorkspace {
  workspaceId: string;
  label: string;
  focused: boolean;
  tabs: HerdrTreeTab[];
}

export type HerdrTreeResult =
  | { available: true; workspaces: HerdrTreeWorkspace[] }
  | { available: false; reason: string };

export type HerdrTabCloseResult = { closed: true } | { closed: false; reason: string };

export interface HerdrAgentSource {
  listAgents(): Promise<HerdrAgentsResult>;
  listTree(): Promise<HerdrTreeResult>;
  closeTab(tabId: string): Promise<HerdrTabCloseResult>;
  findAgent(paneId: string): Promise<HerdrAgentLookup>;
  attachCommand(paneId: string): AttachCommand;
  readAgent(paneId: string, lines: number): Promise<HerdrPreviewResult>;
  readDialog(paneId: string): Promise<HerdrDialogResult>;
  decideAgent(paneId: string, decision: DialogDecision): Promise<HerdrDecisionResult>;
  promptAgent(paneId: string, text: string): Promise<HerdrPromptResult>;
  createTab(request: HerdrTabRequest): Promise<HerdrTabResult>;
}

export class HerdrService implements HerdrAgentSource {
  private requestCounter = 0;

  constructor(private readonly options: HerdrOptions) {}

  async listAgents(): Promise<HerdrAgentsResult> {
    let protocol: number;
    try {
      const pong = asRecord(await this.request("ping", {}));
      protocol = typeof pong.protocol === "number" ? pong.protocol : -1;
    } catch (error) {
      return unavailable(describeConnectionFailure(error));
    }
    if (protocol !== SUPPORTED_PROTOCOL) {
      return unavailable(`Herdr protocol ${protocol} is not supported (expected ${SUPPORTED_PROTOCOL}).`);
    }

    try {
      const result = asRecord(await this.request("agent.list", {}));
      const agents = Array.isArray(result.agents) ? result.agents : [];
      return {
        provider: "herdr",
        available: true,
        protocol,
        agents: agents.map((agent) => parseAgent(asRecord(agent))),
      };
    } catch (error) {
      return unavailable(describeConnectionFailure(error));
    }
  }

  // Workspace → tab → agents hierarchy for the Jump-to sheet. Composed from
  // workspace.list + tab.list (verified shapes: {workspaces: [{workspace_id,
  // label, focused, ...}]} and {tabs: [{tab_id, workspace_id, label, focused,
  // ...}]}) plus the protocol-gated agent list, so every displayed agent
  // carries the same identity the events feed uses.
  async listTree(): Promise<HerdrTreeResult> {
    const agentsResult = await this.listAgents();
    if (!agentsResult.available) {
      return { available: false, reason: agentsResult.reason ?? "Herdr is unavailable." };
    }

    try {
      const [workspacesRaw, tabsRaw] = await Promise.all([
        this.request("workspace.list", {}),
        this.request("tab.list", {}),
      ]);
      const workspaces = asArray(asRecord(workspacesRaw).workspaces).map(asRecord);
      const tabs = asArray(asRecord(tabsRaw).tabs).map(asRecord);

      const agentsByTab = new Map<string, HerdrAgentInfo[]>();
      for (const agent of agentsResult.agents) {
        const existing = agentsByTab.get(agent.tabId) ?? [];
        existing.push(agent);
        agentsByTab.set(agent.tabId, existing);
      }

      const tabsByWorkspace = new Map<string, HerdrTreeTab[]>();
      for (const tab of tabs) {
        const workspaceId = asString(tab.workspace_id);
        const tabId = asString(tab.tab_id);
        if (!workspaceId || !tabId) continue;
        const existing = tabsByWorkspace.get(workspaceId) ?? [];
        existing.push({
          tabId,
          label: asString(tab.label),
          focused: tab.focused === true,
          agents: agentsByTab.get(tabId) ?? [],
        });
        tabsByWorkspace.set(workspaceId, existing);
      }

      return {
        available: true,
        workspaces: workspaces
          .filter((workspace) => asString(workspace.workspace_id) !== "")
          .map((workspace) => ({
            workspaceId: asString(workspace.workspace_id),
            label: asString(workspace.label),
            focused: workspace.focused === true,
            tabs: tabsByWorkspace.get(asString(workspace.workspace_id)) ?? [],
          })),
      };
    } catch (error) {
      return { available: false, reason: describeConnectionFailure(error) };
    }
  }

  async findAgent(paneId: string): Promise<HerdrAgentLookup> {
    const result = await this.listAgents();
    if (!result.available) {
      return { available: false, reason: result.reason ?? "Herdr is unavailable." };
    }
    const agent = result.agents.find((candidate) => candidate.id === paneId);
    return agent ? { available: true, agent } : { available: true };
  }

  attachCommand(paneId: string): AttachCommand {
    return { bin: this.options.bin ?? "herdr", args: ["agent", "attach", paneId] };
  }

  // Bounded plain-text snapshot for session cards. The text comes straight
  // from Herdr's own read API — never scraped or reinterpreted here.
  async readAgent(paneId: string, lines: number): Promise<HerdrPreviewResult> {
    try {
      const result = asRecord(
        await this.request("agent.read", {
          target: paneId,
          source: "recent",
          lines,
          format: "text",
        }),
      );
      return { available: true, preview: extractPreviewText(result) };
    } catch (error) {
      return { available: false, reason: describeConnectionFailure(error) };
    }
  }

  // Reads the pane and returns the parsed permission dialog if one is up.
  // The phone uses this to show the real choices on the Needs-you card.
  async readDialog(paneId: string): Promise<HerdrDialogResult> {
    const read = await this.readAgent(paneId, DIALOG_READ_LINES);
    if (!read.available) return { available: false, reason: read.reason };
    const dialog = parsePermissionDialog(read.preview);
    return dialog ? { present: true, dialog } : { present: false };
  }

  // Answers a waiting permission dialog from the phone (issue #23). This is
  // the one place Mocha fires a key that could take an action, so it re-reads
  // the pane immediately before sending and refuses unless a dialog is still
  // rendered: a card that went stale between the tap and the send must never
  // answer whatever prompt is there now. approve = Enter (confirms the
  // highlighted option); deny = Esc (cancel). The caller is responsible for
  // the outer trust gate (hook overlay + herdr agree the agent is blocked).
  async decideAgent(paneId: string, decision: DialogDecision): Promise<HerdrDecisionResult> {
    const dialog = await this.readDialog(paneId);
    if ("available" in dialog) {
      return { decided: false, reason: dialog.reason };
    }
    if (!dialog.present) {
      return {
        decided: false,
        stale: true,
        reason: "The permission dialog is no longer on screen.",
      };
    }
    const key = decision === "approve" ? "Enter" : "Escape";
    try {
      await this.request("agent.send_keys", { target: paneId, keys: [key] });
      return { decided: true, sent: key };
    } catch (error) {
      return { decided: false, reason: describeConnectionFailure(error) };
    }
  }

  // Submits exactly once and never replays: an uncertain outcome is
  // reported as such, per the no-ambiguous-replay doctrine.
  async promptAgent(paneId: string, text: string): Promise<HerdrPromptResult> {
    const settle = this.options.promptSettleMilliseconds ?? 900;
    // Herdr answers "not an active named agent" while it still considers a
    // started agent launch-pending. The rejection means nothing was
    // delivered, so a short retry is safe and cannot double-submit; any
    // other failure surfaces immediately. Observed live: launch_pending can
    // stay stuck for minutes while the agent is in fact fully interactive,
    // so after the retries we fall back to typing the prompt.
    for (let attempt = 0; ; attempt += 1) {
      try {
        await this.request("agent.prompt", { target: paneId, text });
        await this.ensurePromptSubmitted(paneId, text);
        return { submitted: true };
      } catch (error) {
        const launchPending =
          error instanceof Error && /not an active named agent/i.test(error.message);
        if (!launchPending) {
          return { submitted: false, reason: describeConnectionFailure(error) };
        }
        if (attempt >= 3) {
          return this.typePromptFallback(paneId, text, error);
        }
        await sleep(Math.min(settle, 500));
      }
    }
  }

  // Last-resort delivery when the structured prompt API refuses a visibly
  // interactive agent: type the text and press Enter, exactly as a human
  // would. Guarded to *idle* panes only — typing into a working pane or an
  // open dialog could act on it. Newlines become spaces because send_keys
  // has no bracketed paste; the submission still happens exactly once.
  private async typePromptFallback(
    paneId: string,
    text: string,
    cause: unknown,
  ): Promise<HerdrPromptResult> {
    const lookup = await this.findAgent(paneId);
    if (!lookup.available || !lookup.agent || lookup.agent.status !== "idle") {
      return { submitted: false, reason: describeConnectionFailure(cause) };
    }
    // herdr names whitespace keys: a literal " " is rejected as
    // "unsupported key" (observed live), so spaces travel as "Space".
    const keys = [...text.replace(/\s+/g, " ").trim()].map((ch) => (ch === " " ? "Space" : ch));
    if (keys.length === 0) {
      return { submitted: false, reason: "The prompt is empty." };
    }
    try {
      await this.request("agent.send_keys", { target: paneId, keys: [...keys, "Enter"] });
      return { submitted: true };
    } catch (error) {
      return { submitted: false, reason: describeConnectionFailure(error) };
    }
  }

  // Observed live: a prompt delivered while the agent's UI is still booting
  // lands in its composer without submitting — the text just sits there.
  // Verify and nudge: only while the agent is still *idle* AND the composer
  // visibly still holds the text do we press Enter to complete the send.
  // Any other status means the prompt took (or a dialog may be up, where a
  // blind Enter would answer it) — never touch the pane then.
  private async ensurePromptSubmitted(paneId: string, text: string): Promise<void> {
    const settle = this.options.promptSettleMilliseconds ?? 900;
    const marker = normalizeForComparison(text).slice(-24);
    if (!marker) return;
    for (let attempt = 0; attempt < 3; attempt += 1) {
      await sleep(settle);
      const lookup = await this.findAgent(paneId);
      if (!lookup.available || !lookup.agent) return;
      if (lookup.agent.status !== "idle") return;
      const read = await this.readAgent(paneId, 6);
      if (!read.available) return;
      if (!normalizeForComparison(read.preview).includes(marker)) return;
      await this.request("agent.send_keys", { target: paneId, keys: ["Enter"] }).catch(() => undefined);
    }
  }

  // Verified live: tab.create answers { type: "tab_created", tab, root_pane },
  // and agent.start launches the agent binary in that pane.
  async createTab(request: HerdrTabRequest): Promise<HerdrTabResult> {
    try {
      const created = asRecord(
        await this.request("tab.create", {
          cwd: request.cwd ?? null,
          label: request.label ?? null,
          focus: false,
        }),
      );
      const tabId = asString(asRecord(created.tab).tab_id);
      const paneId = asString(asRecord(created.root_pane).pane_id);
      if (!tabId || !paneId) {
        return { created: false, reason: "Herdr did not report the new tab." };
      }
      if (request.agent) {
        try {
          // The fresh pane's shell needs a moment to boot; until then
          // agent.start answers "not an available shell". Retry briefly.
          await retry(10, 300, () =>
            this.request("agent.start", {
              // Herdr requires a globally unique agent name; the kind alone
              // collides as soon as a second claude/codex exists.
              name: `${request.agent}-${randomBytes(2).toString("hex")}`,
              kind: request.agent,
              pane_id: paneId,
            }),
          );
        } catch (startError) {
          // Don't leave an orphaned empty tab behind a failed launch.
          await this.request("tab.close", { tab_id: tabId }).catch(() => undefined);
          throw startError;
        }
      }
      return { created: true, paneId, tabId };
    } catch (error) {
      return { created: false, reason: describeConnectionFailure(error) };
    }
  }

  async closeTab(tabId: string): Promise<HerdrTabCloseResult> {
    try {
      await this.request("tab.close", { tab_id: tabId });
      return { closed: true };
    } catch (error) {
      return { closed: false, reason: describeConnectionFailure(error) };
    }
  }

  private request(method: string, params: Record<string, unknown>): Promise<unknown> {
    const id = `mocha:${(this.requestCounter += 1)}`;
    const timeoutMilliseconds =
      this.options.requestTimeoutMilliseconds ?? REQUEST_TIMEOUT_MILLISECONDS;

    return new Promise((resolve, reject) => {
      const socket = createConnection({ path: this.options.socketPath });
      let buffered = "";
      let settled = false;

      const finish = (action: () => void) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        socket.destroy();
        action();
      };
      const timer = setTimeout(
        () => finish(() => reject(new Error("Herdr did not respond in time."))),
        timeoutMilliseconds,
      );

      socket.once("error", (error) => finish(() => reject(error)));
      socket.on("connect", () => {
        socket.write(`${JSON.stringify({ id, method, params })}\n`);
      });
      socket.on("data", (chunk) => {
        buffered += chunk.toString("utf8");
        const lineEnd = buffered.indexOf("\n");
        if (lineEnd === -1) return;
        try {
          const message = asRecord(JSON.parse(buffered.slice(0, lineEnd)));
          if (message.id !== id) {
            finish(() => reject(new Error("Herdr answered with a mismatched request id.")));
            return;
          }
          if (message.error !== undefined) {
            const detail = asString(asRecord(message.error).message);
            finish(() =>
              reject(new Error(detail ? `Herdr rejected ${method}: ${detail}` : `Herdr rejected ${method}.`)),
            );
            return;
          }
          finish(() => resolve(message.result));
        } catch {
          finish(() => reject(new Error("Herdr sent a malformed response.")));
        }
      });
    });
  }
}

function parseAgent(agent: Record<string, unknown>): HerdrAgentInfo {
  const status = typeof agent.agent_status === "string" ? agent.agent_status : "unknown";
  const sessionRef = asString(asRecord(agent.agent_session).value);
  return {
    ...(sessionRef ? { sessionRef } : {}),
    id: asString(agent.pane_id),
    agent: asString(agent.agent),
    status: AGENT_STATUSES.includes(status as AgentStatus) ? (status as AgentStatus) : "unknown",
    cwd: asString(agent.cwd),
    title: asString(agent.terminal_title_stripped) || asString(agent.terminal_title),
    workspaceId: asString(agent.workspace_id),
    tabId: asString(agent.tab_id),
    focused: agent.focused === true,
    revision: typeof agent.revision === "number" ? agent.revision : 0,
    authority: "herdr",
  };
}

// Verified live shape: { type: "pane_read", read: { text, truncated, ... } }.
async function retry<T>(attempts: number, delayMilliseconds: number, run: () => Promise<T>): Promise<T> {
  let lastError: unknown;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      return await run();
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, delayMilliseconds));
    }
  }
  throw lastError;
}

function extractPreviewText(result: Record<string, unknown>): string {
  const read = asRecord(result.read);
  if (typeof read.text === "string") return read.text;
  if (typeof result.text === "string") return result.text;
  return "";
}

function unavailable(reason: string): HerdrAgentsResult {
  return { provider: "herdr", available: false, reason, agents: [] };
}

function describeConnectionFailure(error: unknown): string {
  const code =
    error && typeof error === "object" && "code" in error ? (error as { code?: string }).code : undefined;
  if (code === "ENOENT" || code === "ECONNREFUSED") return "The Herdr server is not running.";
  return error instanceof Error ? error.message : "Herdr could not be reached.";
}

function asRecord(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

// Terminal reads wrap and re-space text arbitrarily; compare content only.
function normalizeForComparison(value: string): string {
  return value.replace(/\s+/g, "");
}

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
