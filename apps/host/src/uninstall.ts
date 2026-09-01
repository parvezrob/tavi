import { existsSync, rmSync } from "node:fs";
import type { HostConfig } from "./config.js";

// `tavi uninstall`: everything Tavi put on this computer comes off — the
// background host, the herdr service Tavi started (not one Homebrew runs),
// Tavi's Claude Code hooks, its Tailscale Serve address, and ~/.tavi with
// the paired phones. Tailscale, herdr, and Node stay: they are the person's.
export interface UninstallDeps {
  ask: (question: string) => Promise<boolean>;
  report: (message: string) => void;
  uninstallService: () => Promise<void>;
  uninstallHerdrService: () => Promise<void>;
  removeClaudeHooks: () => boolean;
  /** Tailscale Serve handlers as [host, proxy target]; empty when Tailscale is absent. */
  serveHandlers: () => Promise<Array<[string, string]>>;
  resetServe: () => Promise<void>;
  /** Removes the `tavi` shim `pair` wrote (#64); returns where it was, or undefined when there was none. */
  removeCommandLink: () => string | undefined;
}

export async function uninstall(config: HostConfig, deps: UninstallDeps): Promise<boolean> {
  deps.report("\nRemove Tavi from this computer?\n");
  deps.report("  This stops the background host, forgets every paired phone, removes Tavi's Claude Code hooks");
  deps.report("  and its Tailscale address. Tailscale, herdr, and Node.js stay — they are yours.\n");
  if (!(await deps.ask("Go ahead?"))) {
    deps.report("Nothing changed.");
    return false;
  }
  deps.report("");

  await step(deps, "Background host stopped and removed", deps.uninstallService);
  await step(deps, "herdr service started by Tavi removed", deps.uninstallHerdrService);
  await step(deps, "`tavi` command removed", async () => deps.removeCommandLink() ?? "none was installed");
  await step(deps, "Claude Code hooks removed", async () => {
    if (!deps.removeClaudeHooks()) return "none were installed";
    return undefined;
  });
  await step(deps, "Tailscale address removed", async () => {
    const handlers = await deps.serveHandlers();
    if (handlers.length === 0) return "none was set";
    const ours = handlers.filter(([, proxy]) => new RegExp(`:${config.port}$`).test(proxy));
    if (ours.length === 0) return "none was Tavi's";
    if (ours.length !== handlers.length) {
      return `left alone — Tailscale Serve also carries something else of yours; run \`tailscale serve status\` and remove Tavi's :${config.port} entry yourself`;
    }
    await deps.resetServe();
    return undefined;
  });
  await step(deps, "Pairing data and Tavi's files removed", async () => {
    if (!existsSync(config.stateDir)) return "already gone";
    rmSync(config.stateDir, { recursive: true, force: true });
    return undefined;
  });

  deps.report("\nTavi is gone from this computer. On the phone, remove this computer under Settings → Manage access.");
  deps.report("Still installed, in case you want them removed too: Tailscale (its app / package), herdr (`brew uninstall herdr` or delete the binary), Node.js.");
  return true;
}

async function step(deps: UninstallDeps, done: string, run: () => Promise<string | undefined | void>): Promise<void> {
  try {
    const note = await run();
    deps.report(`  ✓ ${done}${note ? `  (${note})` : ""}`);
  } catch (error) {
    deps.report(`  – ${done}: could not — ${error instanceof Error ? error.message.split("\n")[0] : String(error)}`);
  }
}
