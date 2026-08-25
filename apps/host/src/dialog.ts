// Parses a Claude Code permission / confirmation dialog out of a pane's
// rendered text (issue #23). These dialogs share one shape:
//
//    Do you want to proceed?
//    ❯ 1. Yes
//      2. Yes, and don't ask again
//      3. No, and tell Claude what to do differently
//
//    Enter to confirm · Esc to cancel
//
// The `❯` marks the highlighted option; plain Enter confirms it and Esc
// cancels. We detect a dialog only when both a numbered option list and the
// confirm/cancel footer are present, so ordinary transcript text that merely
// contains a numbered list can never be mistaken for a live prompt.

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
// Claude Code renders "Enter to confirm · Esc to cancel"; match loosely so a
// wording tweak (different middot, "cancel"/"go back") still counts.
const FOOTER_PATTERN = /enter\s+to\s+confirm.*esc/i;

export function parsePermissionDialog(text: string): PermissionDialog | undefined {
  const lines = text.split("\n");
  if (!lines.some((line) => FOOTER_PATTERN.test(line))) return undefined;

  const options: DialogOption[] = [];
  let firstOptionLine = -1;
  for (let i = 0; i < lines.length; i += 1) {
    const match = lines[i]?.match(OPTION_PATTERN);
    if (!match) continue;
    const index = Number.parseInt(match[2] ?? "", 10);
    if (!Number.isInteger(index)) continue;
    if (firstOptionLine === -1) firstOptionLine = i;
    options.push({ index, label: match[3] ?? "", selected: Boolean(match[1]) });
  }
  // A footer without a numbered list is a text hint, not an actionable
  // dialog. Require at least two options so we never fire keys at a lone
  // spinner line that happens to end in "1.".
  if (options.length < 2) return undefined;

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
