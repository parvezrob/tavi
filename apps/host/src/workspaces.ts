import { readdir, stat } from "node:fs/promises";
import path from "node:path";
import { isRemovalLeftover } from "./removal-sweep.js";
import type { WorkspaceInfo } from "./types.js";

const MAX_WORKSPACES = 160;

// The browsable folders under the configured roots, for the New Agent
// picker (#24): each root itself plus its immediate visible subfolders,
// git repositories first. Roots that are missing or unreadable (removable
// drives, unmounted shares) are skipped, never an error.
export async function scanWorkspaces(roots: string[]): Promise<WorkspaceInfo[]> {
  const workspaces = new Map<string, WorkspaceInfo>();

  for (const root of roots) {
    try {
      const rootStat = await stat(root);
      if (!rootStat.isDirectory()) continue;
      workspaces.set(root, { name: path.basename(root), path: root, git: await isGitRoot(root) });

      const entries = await readdir(root, { withFileTypes: true });
      for (const entry of entries) {
        // A folder a removed worktree left behind is not a place to work
        // (#82); the host deletes it when it can.
        if (!entry.isDirectory() || entry.name.startsWith(".") || isRemovalLeftover(entry.name)) continue;
        const candidate = path.join(root, entry.name);
        workspaces.set(candidate, { name: entry.name, path: candidate, git: await isGitRoot(candidate) });
        if (workspaces.size >= MAX_WORKSPACES) break;
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

function isGitRoot(directory: string): Promise<boolean> {
  return stat(path.join(directory, ".git"))
    .then(() => true)
    .catch(() => false);
}
