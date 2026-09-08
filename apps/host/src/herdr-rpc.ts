import { createConnection } from "node:net";
import type { HerdrOptions } from "./herdr-types.js";

// One request to herdr's socket: newline-delimited JSON, {id, method,
// params} out and {id, result} back, one connection each, with a timeout.
// Split out of herdr.ts in #98 — the transport and the method surface over
// it are two reasons to change. The reply coercions live here too: every
// reply passes through this module, and it is the only file both readers of
// them (`herdr.ts` and `herdr-tabs.ts`) can import without a cycle.

const REQUEST_TIMEOUT_MILLISECONDS = 2_000;

// A herdr that missed the deadline once has said nothing about being gone:
// on a loaded Mac the reply lands moments later (#111 — one 2 s timeout
// emptied the owner's home while herdr answered the very next call in
// 0.32 s). Typed so a read can be retried and nothing else is.
export class HerdrTimeoutError extends Error {
  constructor() {
    super("Herdr did not respond in time.");
    this.name = "HerdrTimeoutError";
  }
}

export class HerdrRpc {
  private requestCounter = 0;

  constructor(private readonly options: HerdrOptions) {}

  // One retry, reads only. The second socket is opened only when the first
  // call timed out, so a healthy call still costs exactly one connection
  // (#68 finding 3 counts them). Never for a write: an agent.send_keys or
  // agent.prompt that timed out may well have landed, and replaying it would
  // press the key twice — the no-ambiguous-replay rule.
  async requestIdempotent(method: string, params: Record<string, unknown>): Promise<unknown> {
    try {
      return await this.request(method, params);
    } catch (error) {
      if (!(error instanceof HerdrTimeoutError)) throw error;
      return await this.request(method, params);
    }
  }

  request(method: string, params: Record<string, unknown>): Promise<unknown> {
    // biome-ignore lint/suspicious/noAssignInExpressions: the id must be unique per request, and the counter has no other reader.
    const id = `tavi:${(this.requestCounter += 1)}`;
    const timeoutMilliseconds = this.options.requestTimeoutMilliseconds ?? REQUEST_TIMEOUT_MILLISECONDS;

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
      const timer = setTimeout(() => finish(() => reject(new HerdrTimeoutError())), timeoutMilliseconds);

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
          // Not swallowed: a reply that will not parse becomes the caller's
          // rejection, the same as any other failed request.
          finish(() => reject(new Error("Herdr sent a malformed response.")));
        }
      });
    });
  }
}

export function describeConnectionFailure(error: unknown): string {
  const code = error && typeof error === "object" && "code" in error ? (error as { code?: string }).code : undefined;
  if (code === "ENOENT" || code === "ECONNREFUSED") return "The Herdr server is not running.";
  return error instanceof Error ? error.message : "Herdr could not be reached.";
}

export function asRecord(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
}

export function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

export function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

export function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
