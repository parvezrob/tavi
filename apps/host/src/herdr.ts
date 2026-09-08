import { SHELL_KIND } from "./agent-kinds.js";
import { parsePermissionDialog } from "./dialog.js";
import { asArray, asRecord, asString, describeConnectionFailure, HerdrRpc, sleep } from "./herdr-rpc.js";
import { closeTab, createTab, listTree, renameTab } from "./herdr-tabs.js";
import type {
  DialogDecision,
  HerdrAgentLookup,
  HerdrAgentSource,
  HerdrDecisionResult,
  HerdrDialogResult,
  HerdrOptions,
  HerdrPreviewResult,
  HerdrPromptResult,
  HerdrTabCloseResult,
  HerdrTabRenameResult,
  HerdrTabRequest,
  HerdrTabResult,
  HerdrTreeResult,
  TerminalSize,
} from "./herdr-types.js";
import type { AgentStatus, AttachCommand, HerdrAgentInfo, HerdrAgentsResult } from "./types.js";

// Verified against herdr 0.7.5. The socket speaks newline-delimited JSON:
// {id, method, params} -> {id, result}. Gate on the protocol number so an
// incompatible herdr degrades to "unavailable" instead of mis-parsed state.
// Verified live: protocol 17 (herdr 0.7.5, 2026-08-25) and 20 (herdr
// 0.8.2, 2026-09-01) — same shapes for every method used here; herdr adds
// fields and keeps the old ones, and its own guidance is to tolerate unknown
// fields. So the gate is: at least the oldest verified protocol, and an
// agent.list that still has the shape Tavi reads. A newer herdr that keeps
// the shape just works; one that breaks it degrades to "unavailable" with an
// update hint rather than mis-parsing.
const AGENT_STATUSES: readonly AgentStatus[] = ["idle", "working", "blocked", "done", "unknown"];
const MIN_PROTOCOL = 17;
// Enough lines to always capture a dialog's option list plus its footer.
const DIALOG_READ_LINES = 40;

export class HerdrService implements HerdrAgentSource {
  private readonly rpc: HerdrRpc;

  constructor(private readonly options: HerdrOptions) {
    this.rpc = new HerdrRpc(options);
  }

  renameTab(tabId: string, label: string): Promise<HerdrTabRenameResult> {
    return renameTab(this.rpc, tabId, label);
  }

  async listTree(): Promise<HerdrTreeResult> {
    return listTree(this.rpc, await this.listAgents());
  }

  createTab(request: HerdrTabRequest): Promise<HerdrTabResult> {
    return createTab(this.rpc, request, (paneId) => this.reportShellPane(paneId));
  }

  closeTab(tabId: string): Promise<HerdrTabCloseResult> {
    return closeTab(this.rpc, tabId);
  }

  async listAgents(): Promise<HerdrAgentsResult> {
    let protocol: number;
    try {
      // The home hangs on this call: its reads retry once (#111).
      const pong = asRecord(await this.rpc.requestIdempotent("ping", {}));
      protocol = typeof pong.protocol === "number" ? pong.protocol : -1;
    } catch (error) {
      return unavailable(describeConnectionFailure(error));
    }
    if (protocol < MIN_PROTOCOL) {
      return unavailable(
        `This herdr is too old for Tavi (protocol ${protocol}; Tavi needs ${MIN_PROTOCOL} or newer). Update herdr: brew upgrade herdr`,
      );
    }

    try {
      // The user's name for a tab (herdr tab rename, #55) is identity on
      // the phone. Joined here so every consumer — the REST list, the
      // events feed, the tree — carries the same label. Fetched alongside
      // the list (one round-trip of latency, not two) and as enrichment
      // only: a failed tab.list must never take the agent list down.
      const [result, labels] = await Promise.all([
        this.rpc.requestIdempotent("agent.list", {}).then(asRecord),
        this.rpc
          .requestIdempotent("tab.list", {})
          .then(tabLabels)
          .catch(() => new Map<string, string>()),
      ]);
      if (!Array.isArray(result.agents)) {
        return unavailable(
          `This herdr (protocol ${protocol}) answers in a way Tavi does not understand. Update Tavi: npx tavi-host@latest pair`,
        );
      }
      const agents = result.agents;
      if (agents.some((raw) => !asString(asRecord(raw).pane_id) || !asString(asRecord(raw).agent_status))) {
        return unavailable(
          `This herdr (protocol ${protocol}) describes agents in a way Tavi does not understand. Update Tavi: npx tavi-host@latest pair`,
        );
      }
      return {
        provider: "herdr",
        available: true,
        protocol,
        agents: agents.map((raw) => {
          const parsed = parseAgent(asRecord(raw));
          const label = labels.get(parsed.tabId);
          return label ? { ...parsed, tabLabel: label } : parsed;
        }),
      };
    } catch (error) {
      return unavailable(describeConnectionFailure(error));
    }
  }

  // Verified live (#44): an external attach sets the pane's *terminal* size
  // and herdr keeps whatever the last attach said even after that client
  // leaves — it does not clamp to its own viewer. The viewer's layout rect
  // (session.snapshot → layouts[].panes[].rect) is the size the Mac actually
  // displays, so it is the size to hand back on detach.
  async paneSize(paneId: string): Promise<TerminalSize | undefined> {
    try {
      const snapshot = asRecord(asRecord(await this.rpc.request("session.snapshot", {})).snapshot);
      for (const layout of asArray(snapshot.layouts).map(asRecord)) {
        for (const pane of asArray(layout.panes).map(asRecord)) {
          if (asString(pane.pane_id) !== paneId) continue;
          const rect = asRecord(pane.rect);
          const cols = typeof rect.width === "number" ? rect.width : 0;
          const rows = typeof rect.height === "number" ? rect.height : 0;
          return cols > 0 && rows > 0 ? { cols, rows } : undefined;
        }
      }
      return undefined;
    } catch {
      // The size is a nicety for the hand-back; not knowing it leaves the
      // pane at whatever size it already has.
      return undefined;
    }
  }

  // Verified live (2026-09-02, #66): pane.report_agent {source:"tavi",
  // agent:"shell", state:"idle"} lists a plain pane as a Terminal; herdr then
  // ignores its own detection for that pane. pane.release_agent with the
  // same source and label drops the report, and herdr's detection labels
  // the pane on its own within ~3 s (a running claude reads agent "claude",
  // status from the screen). When that agent exits, the pane leaves
  // agent.list entirely — reporting shell again brings the Terminal back.
  async reportShellPane(paneId: string): Promise<void> {
    await this.rpc.request("pane.report_agent", {
      pane_id: paneId,
      source: "tavi",
      agent: SHELL_KIND,
      state: "idle",
    });
  }

  async releaseShellAuthority(paneId: string): Promise<void> {
    await this.rpc.request("pane.release_agent", {
      pane_id: paneId,
      source: "tavi",
      agent: SHELL_KIND,
    });
  }

  // pane.get answers { type: "pane_info", pane } for a live pane and an
  // error for one that is gone.
  async paneExists(paneId: string): Promise<boolean> {
    try {
      const result = asRecord(await this.rpc.request("pane.get", { pane_id: paneId }));
      return asRecord(result.pane).pane_id === paneId;
    } catch {
      // pane.get errors for a pane that is gone, which is the answer.
      return false;
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

  // `--takeover` always: Tavi is the only external attach client a pane
  // has, and a fresh attach often lands while the previous one (a phone that
  // dropped, or the retained pty being disposed a millisecond earlier) is
  // still registered with herdr — without the flag herdr refuses with
  // "already has an attached client", the pty exits at once, and the phone
  // shows a Claude session as ended (owner, robin-PC, 2026-09-02).
  attachCommand(paneId: string): AttachCommand {
    return { bin: this.options.bin ?? "herdr", args: ["agent", "attach", paneId, "--takeover"] };
  }

  // Bounded plain-text snapshot for session cards. The text comes straight
  // from Herdr's own read API — never scraped or reinterpreted here. `source`
  // picks the buffer: "recent" is a rolling window of recent output (good for
  // an activity preview); "visible" is the current on-screen viewport.
  async readAgent(paneId: string, lines: number, source: "recent" | "visible" = "recent"): Promise<HerdrPreviewResult> {
    try {
      const result = asRecord(
        await this.rpc.request("agent.read", {
          target: paneId,
          source,
          lines,
          format: "text",
        }),
      );
      // Verified live shape: { type: "pane_read", read: { text, truncated, … } }.
      const read = asRecord(result.read);
      const preview = typeof read.text === "string" ? read.text : typeof result.text === "string" ? result.text : "";
      return { available: true, preview };
    } catch (error) {
      return { available: false, reason: describeConnectionFailure(error) };
    }
  }

  // Reads the pane and returns the parsed permission dialog if one is up.
  // Uses the "visible" viewport, not "recent" output: a dialog is defined by
  // being on screen right now, and the rolling "recent" window can scroll a
  // statically-displayed dialog out when the status line repaints — which
  // showed up as the sheet falsely reporting "already resolved" (#23).
  async readDialog(paneId: string): Promise<HerdrDialogResult> {
    const read = await this.readAgent(paneId, DIALOG_READ_LINES, "visible");
    if (!read.available) return { available: false, reason: read.reason };
    const dialog = parsePermissionDialog(read.preview);
    return dialog ? { present: true, dialog } : { present: false };
  }

  // Answers a waiting permission dialog from the phone (issue #23). This is
  // the one place Tavi fires a key that could take an action, so it re-reads
  // the pane immediately before sending and refuses unless a dialog is still
  // rendered: a card that went stale between the tap and the send must never
  // answer whatever prompt is there now. approve = Enter (confirms the
  // highlighted option); deny = Esc (cancel); { option: N } presses that
  // digit, which Claude Code treats as select-and-confirm — but only after
  // re-confirming N is a real option in the dialog still on screen, so a
  // stale option number can never land on a different prompt. The caller is
  // responsible for the outer trust gate (an authority agrees it is blocked).
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
    let key: string;
    if (decision === "approve") {
      key = "Enter";
    } else if (decision === "deny") {
      key = "Escape";
    } else {
      const exists = dialog.dialog.options.some((option) => option.index === decision.option);
      if (!exists) {
        return {
          decided: false,
          stale: true,
          reason: "That option is no longer offered by the dialog on screen.",
        };
      }
      key = String(decision.option);
    }
    try {
      await this.rpc.request("agent.send_keys", { target: paneId, keys: [key] });
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
        await this.rpc.request("agent.prompt", { target: paneId, text });
        await this.ensurePromptSubmitted(paneId, text);
        return { submitted: true };
      } catch (error) {
        const launchPending = error instanceof Error && /not an active named agent/i.test(error.message);
        if (!launchPending) {
          return { submitted: false, reason: describeConnectionFailure(error) };
        }
        // Four tries at ~0.5 s: an agent herdr has only just launched is not
        // a named agent yet, and that window is short. Past it the pane is
        // real but the API will not have it, so typing is the only way in.
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
  private async typePromptFallback(paneId: string, text: string, cause: unknown): Promise<HerdrPromptResult> {
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
      await this.rpc.request("agent.send_keys", { target: paneId, keys: [...keys, "Enter"] });
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
      await this.rpc.request("agent.send_keys", { target: paneId, keys: ["Enter"] }).catch(() => undefined);
    }
  }
}

// tab.list → the user's label per tab id; entries without both are dropped.
function tabLabels(raw: unknown): Map<string, string> {
  const map = new Map<string, string>();
  for (const tab of asArray(asRecord(raw).tabs).map(asRecord)) {
    const tabId = asString(tab.tab_id);
    const label = asString(tab.label);
    if (tabId && label) map.set(tabId, label);
  }
  return map;
}

function parseAgent(agent: Record<string, unknown>): HerdrAgentInfo {
  const status = typeof agent.agent_status === "string" ? agent.agent_status : "unknown";
  const session = asRecord(agent.agent_session);
  const sessionRef = asString(session.value);
  const detectedAgent = asString(session.agent);
  const label = asString(agent.agent);
  // Herdr reads "idle after having worked" as done, and a Terminal that
  // hosted an agent (#66) inherits that when Tavi reports it as shell again.
  // A shell has no task to finish: it is idle. (Verified live 2026-09-02:
  // report state idle → agent_status "done" once the pane had been working.)
  const normalized = label === SHELL_KIND && status === "done" ? "idle" : status;
  return {
    ...(sessionRef ? { sessionRef } : {}),
    ...(detectedAgent && detectedAgent !== label ? { detectedAgent } : {}),
    id: asString(agent.pane_id),
    agent: label,
    status: AGENT_STATUSES.includes(normalized as AgentStatus) ? (normalized as AgentStatus) : "unknown",
    cwd: asString(agent.cwd),
    title: asString(agent.terminal_title_stripped) || asString(agent.terminal_title),
    workspaceId: asString(agent.workspace_id),
    tabId: asString(agent.tab_id),
    focused: agent.focused === true,
    revision: typeof agent.revision === "number" ? agent.revision : 0,
    authority: "herdr",
  };
}

function unavailable(reason: string): HerdrAgentsResult {
  return { provider: "herdr", available: false, reason, agents: [] };
}

// Terminal reads wrap and re-space text arbitrarily; compare content only.
function normalizeForComparison(value: string): string {
  return value.replace(/\s+/g, "");
}
