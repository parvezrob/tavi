export const TERMINAL_PROTOCOL = "mocha.v1";
export const MAX_TERMINAL_FRAME_BYTES = 64 * 1024;

import type { ClientTerminalMessage } from "./types.js";

export function parseClientTerminalMessage(value: unknown): ClientTerminalMessage | undefined {
  if (!isRecord(value) || typeof value.type !== "string") return undefined;

  switch (value.type) {
    case "input":
      return typeof value.data === "string" ? { type: "input", data: value.data } : undefined;
    case "resize":
      return Number.isInteger(value.cols) && Number.isInteger(value.rows)
        ? { type: "resize", cols: value.cols as number, rows: value.rows as number }
        : undefined;
    case "ping":
      return typeof value.id === "string" && /^[A-Za-z0-9-]{1,64}$/.test(value.id)
        ? { type: "ping", id: value.id }
        : undefined;
    default:
      return undefined;
  }
}

export function chunkTerminalOutput(data: string): string[] {
  if (data.length === 0) return [];
  if (terminalOutputFrameBytes(data) <= MAX_TERMINAL_FRAME_BYTES) return [data];

  const chunks: string[] = [];
  let parts: string[] = [];
  let frameBytes = terminalOutputFrameBytes("");

  for (const scalar of data) {
    const scalarBytes = Buffer.byteLength(JSON.stringify(scalar)) - 2;
    if (parts.length > 0 && frameBytes + scalarBytes > MAX_TERMINAL_FRAME_BYTES) {
      chunks.push(parts.join(""));
      parts = [];
      frameBytes = terminalOutputFrameBytes("");
    }
    parts.push(scalar);
    frameBytes += scalarBytes;
  }
  if (parts.length > 0) chunks.push(parts.join(""));
  return chunks;
}

function terminalOutputFrameBytes(data: string): number {
  return Buffer.byteLength(JSON.stringify({ type: "output", data }));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
