import { promises as fs } from "node:fs";
import path from "node:path";

// Folders a removed worktree leaves behind (#82, #83). `removeWorktree`
// renames the checkout to `<path>.removing-<stamp>` before deregistering
// it and deletes the folder in the background; when that delete fails
// (permissions, a busy file) or the host restarts mid-delete, the folder
// survives inside a root — full of the checkout, unknown to git. So: it is
// never offered by the picker's root scan, the host retries the delete on
// start and once an hour, and `tavi doctor` names what still could not go.
//
// Only names the host itself made are touched — `<anything>.removing-<base36
// stamp>` — and only under the roots: one level down (a worktree beside its
// repository) and inside a `<repo>-worktrees` folder (where the host puts
// the ones it creates). Nothing else is ever deleted here.

const LEFTOVER = /\.removing-[0-9a-z]+$/;
const WORKTREES_FOLDER = /-worktrees$/;
export const SWEEP_INTERVAL_MS = 60 * 60 * 1_000;

export function leftoverName(worktreePath: string): string {
  return `${worktreePath}.removing-${Date.now().toString(36)}`;
}

export function isRemovalLeftover(name: string): boolean {
  return LEFTOVER.test(name);
}

// Every leftover under the roots, deepest first, without touching any.
export async function listRemovalLeftovers(roots: readonly string[]): Promise<string[]> {
  const found = new Set<string>();
  for (const root of roots) {
    for (const entry of await directories(root)) {
      if (isRemovalLeftover(entry)) found.add(path.join(root, entry));
      else if (WORKTREES_FOLDER.test(entry)) {
        const folder = path.join(root, entry);
        for (const inner of await directories(folder)) {
          if (isRemovalLeftover(inner)) found.add(path.join(folder, inner));
        }
      }
    }
  }
  return [...found].sort();
}

export interface SweepReport {
  removed: string[];
  // What still could not be deleted, with the reason, for the log and for
  // `tavi doctor`.
  stranded: { path: string; error: string }[];
}

export async function sweepRemovalLeftovers(roots: readonly string[]): Promise<SweepReport> {
  const report: SweepReport = { removed: [], stranded: [] };
  for (const leftover of await listRemovalLeftovers(roots)) {
    try {
      await fs.rm(leftover, { recursive: true, force: true });
      report.removed.push(leftover);
    } catch (error) {
      report.stranded.push({ path: leftover, error: error instanceof Error ? error.message : String(error) });
    }
  }
  return report;
}

// One sentence per outcome for the host log; nothing when there was
// nothing to do.
export function describeSweep(report: SweepReport): string[] {
  const lines: string[] = [];
  if (report.removed.length > 0)
    lines.push(
      `tavi: deleted ${report.removed.length} folder${report.removed.length === 1 ? "" : "s"} left by removed worktrees: ${report.removed.join(", ")}`,
    );
  for (const { path: leftover, error } of report.stranded)
    lines.push(`tavi: could not delete ${leftover} (left by a removed worktree): ${error}`);
  return lines;
}

async function directories(folder: string): Promise<string[]> {
  try {
    const entries = await fs.readdir(folder, { withFileTypes: true });
    return entries.filter((entry) => entry.isDirectory()).map((entry) => entry.name);
  } catch {
    // A root that is missing or unreadable (a removable drive) has nothing
    // to sweep.
    return [];
  }
}
