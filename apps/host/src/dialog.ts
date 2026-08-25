// Parses a Claude Code permission / confirmation dialog out of a pane's
// rendered text (issue #23). Claude has many project-decision prompts — trust
// folder, Bash approval, file-edit approval, MCP tool approval, plan approval
// — and their footers differ ("Enter to confirm · Esc to cancel", "Esc to
// cancel · Tab to amend · ctrl+e to explain", …). What they all share is the
// structure: a numbered option list with the highlighted choice marked `❯`.
//
//    Do you want to proceed?          Quick safety check: … trust this folder?
//    ❯ 1. Yes                         ❯ 1. Yes, I trust this folder
//      2. Yes, and always allow …       2. No, exit
//      3. No
//    Esc to cancel · Tab to amend …   Enter to confirm · Esc to cancel
//
// So detection keys on that structure, not on footer wording: an option list
// with a selected arrow. That is robust to new prompt types, where footer
// matching would silently miss them. A recognized footer is accepted as a
// secondary signal for the rare capture that clips the arrow. The interaction
// is identical across all of them — Enter confirms the highlighted option,
// Esc cancels — so approve/deny is generic. The `❯` arrow is Claude's own
// chrome for an active menu; ordinary transcript text never prefixes a
// numbered item with it, so prose can't be mistaken for a live prompt.

export interface DialogOption {
  index: number;
  label: string;
  selected: boolean;
}

export interface PermissionDialog {
  // The nearest non-empty line above the option list — the question being
  // asked. Best-effort; may be empty.
  prompt: string;
  options: DialogOption[];
}

const OPTION_PATTERN = /^\s*(❯\s*)?(\d+)\.\s+(.*\S)\s*$/;
// Secondary acceptor only. Matches the control-hint footers Claude shows
// under a prompt, loosely enough to survive wording tweaks. Detection does
// not depend on it — the highlighted option list is the primary signal.
const FOOTER_PATTERN = /esc(?:ape)?\s+to\s+cancel|enter\s+to\s+confirm|tab\s+to\s+amend/i;

export function parsePermissionDialog(text: string): PermissionDialog | undefined {
  const lines = text.split("\n");

  const options: DialogOption[] = [];
  let firstOptionLine = -1;
  let hasArrow = false;
  for (let i = 0; i < lines.length; i += 1) {
    const match = lines[i]?.match(OPTION_PATTERN);
    if (!match) continue;
    const index = Number.parseInt(match[2] ?? "", 10);
    if (!Number.isInteger(index)) continue;
    if (firstOptionLine === -1) firstOptionLine = i;
    const selected = Boolean(match[1]);
    hasArrow ||= selected;
    options.push({ index, label: match[3] ?? "", selected });
  }
  // Require a numbered list of at least two options so a lone spinner line
  // ending in "1." is never mistaken for a dialog.
  if (options.length < 2) return undefined;
  // The `❯` selection arrow is Claude's chrome for an active menu and is the
  // structural signature of a live prompt — robust across every project-
  // decision dialog regardless of footer wording. A recognized footer is
  // accepted as a fallback for the rare read that clips the arrow line. Prose
  // that merely lists numbered items has neither and is correctly ignored.
  if (!hasArrow && !lines.some((line) => FOOTER_PATTERN.test(line))) return undefined;

  let prompt = "";
  for (let i = firstOptionLine - 1; i >= 0; i -= 1) {
    const candidate = (lines[i] ?? "").trim();
    if (candidate) {
      prompt = candidate;
      break;
    }
  }

  return { prompt, options };
}
