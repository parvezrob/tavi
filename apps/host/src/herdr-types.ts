import type { PermissionDialog } from "./dialog.js";
import type { HerdrAgentInfo, HerdrAgentsResult, AttachCommand } from "./types.js";

// What Tavi asks of herdr and what it gets back — the contract every
// consumer (the routes, the events feed, the terminal bridge) depends on,
// with `herdr.ts` as its one implementation. Split out of herdr.ts in #98.

export interface HerdrOptions {
  socketPath: string;
  bin?: string;
  requestTimeoutMilliseconds?: number;
  promptSettleMilliseconds?: number;
}

export type HerdrAgentLookup = { available: true; agent?: HerdrAgentInfo } | { available: false; reason: string };

export type HerdrPreviewResult = { available: true; preview: string } | { available: false; reason: string };

export type HerdrPromptResult = { submitted: true } | { submitted: false; reason: string };

// approve = Enter (confirm the highlighted option); deny = Esc (cancel);
// { option } = pick a specific numbered option by pressing its digit, which
// Claude Code treats as select-and-confirm.
export type DialogDecision = "approve" | "deny" | { option: number };

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

export type HerdrTabResult = { created: true; paneId: string; tabId: string } | { created: false; reason: string };

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

export type HerdrTabRenameResult = { renamed: true; label: string } | { renamed: false; reason: string };

export interface TerminalSize {
  cols: number;
  rows: number;
}

export interface HerdrAgentSource {
  listAgents(): Promise<HerdrAgentsResult>;
  // The pane's cell size in herdr's own viewer layout — what the Mac shows.
  // Optional: a source that cannot report it leaves the pane untouched.
  paneSize?(paneId: string): Promise<TerminalSize | undefined>;
  listTree(): Promise<HerdrTreeResult>;
  closeTab(tabId: string): Promise<HerdrTabCloseResult>;
  renameTab(tabId: string, label: string): Promise<HerdrTabRenameResult>;
  findAgent(paneId: string): Promise<HerdrAgentLookup>;
  attachCommand(paneId: string): AttachCommand;
  readAgent(paneId: string, lines: number): Promise<HerdrPreviewResult>;
  readDialog(paneId: string): Promise<HerdrDialogResult>;
  // Terminal panes Tavi reported as "shell" (#66). Optional: a source that
  // cannot do these leaves such panes labelled as they are.
  releaseShellAuthority?(paneId: string): Promise<void>;
  reportShellPane?(paneId: string): Promise<void>;
  paneExists?(paneId: string): Promise<boolean>;
  decideAgent(paneId: string, decision: DialogDecision): Promise<HerdrDecisionResult>;
  promptAgent(paneId: string, text: string): Promise<HerdrPromptResult>;
  createTab(request: HerdrTabRequest): Promise<HerdrTabResult>;
}
