import { createConnection } from "node:net";
import type { AgentStatus, HerdrAgentInfo, HerdrAgentsResult } from "./types.js";

// Verified against herdr 0.7.5. The socket speaks newline-delimited JSON:
// {id, method, params} -> {id, result}. Gate on the protocol number so an
// incompatible herdr degrades to "unavailable" instead of mis-parsed state.
const SUPPORTED_PROTOCOL = 17;
const REQUEST_TIMEOUT_MILLISECONDS = 2_000;
const AGENT_STATUSES: readonly AgentStatus[] = ["idle", "working", "blocked", "done", "unknown"];

export interface HerdrOptions {
  socketPath: string;
  requestTimeoutMilliseconds?: number;
}

export interface HerdrAgentSource {
  listAgents(): Promise<HerdrAgentsResult>;
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
            finish(() => reject(new Error(`Herdr rejected ${method}.`)));
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
  return {
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
