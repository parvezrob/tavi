import type { IncomingMessage, ServerResponse } from "node:http";
import type { AgentKindDetector } from "./agent-kinds.js";
import type { AttentionOverlay } from "./attention.js";
import type { HostConfig } from "./config.js";
import type { GhRunner } from "./gh.js";
import type { PullRequestLookup } from "./git.js";
import type { HerdrAgentSource } from "./herdr.js";
import type { DeviceRegistry, PairingSessions } from "./pairing.js";
import type { DiscoveryDeps, PreviewRegistry } from "./preview.js";
import type { ProjectHistory } from "./projects.js";
import type { TailscaleRunner } from "./tailscale.js";
import type { WorkspaceInfo } from "./types.js";
import { InputError } from "./validation.js";

const MAX_BODY_BYTES = 64 * 1024;

export interface RouteContext {
  config: HostConfig;
  listWorkspaces: (roots: string[]) => Promise<WorkspaceInfo[]>;
  projects: ProjectHistory;
  agentKinds: AgentKindDetector;
  devices: DeviceRegistry;
  pairing: PairingSessions;
  authorized: (request: IncomingMessage) => boolean;
  herdr?: HerdrAgentSource | undefined;
  attention?: AttentionOverlay | undefined;
  update?: (() => Promise<unknown>) | undefined;
  previews: PreviewRegistry;
  doorReady: () => Promise<boolean>;
  discovery?: (DiscoveryDeps & { kill?: (pid: number) => void }) | undefined;
  pullRequests?: PullRequestLookup | undefined;
  gh?: GhRunner | undefined;
  tailscale?: TailscaleRunner | undefined;
}

// `true` means handled.
export type Route = (
  url: URL,
  request: IncomingMessage,
  response: ServerResponse,
  context: RouteContext,
) => Promise<boolean>;

export async function readJsonBody(request: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buffer.length;
    if (size > MAX_BODY_BYTES) throw new InputError("Request body is too large.");
    chunks.push(buffer);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new InputError("Request body must be valid JSON.");
  }
}

export function sendJson(response: ServerResponse, status: number, value: unknown): void {
  if (response.headersSent) return;
  const body = JSON.stringify(value);
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store",
  });
  response.end(body);
}
