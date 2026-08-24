export const TERMINAL_PROTOCOL = "mocha.v1";
export const TERMINAL_PROTOCOL_V2 = "mocha.v2";
export const MAX_TERMINAL_FRAME_BYTES = 64 * 1024;

// v2 output frame: [0x01][8-byte BE start offset][raw output bytes].
export const OUTPUT_FRAME_TYPE = 0x01;
export const OUTPUT_FRAME_HEADER_BYTES = 9;
export const MAX_OUTPUT_PAYLOAD_BYTES = MAX_TERMINAL_FRAME_BYTES - OUTPUT_FRAME_HEADER_BYTES;

export function encodeOutputFrame(startOffset: number, payload: Buffer): Buffer {
  const frame = Buffer.allocUnsafe(OUTPUT_FRAME_HEADER_BYTES + payload.length);
  frame[0] = OUTPUT_FRAME_TYPE;
  frame.writeBigUInt64BE(BigInt(startOffset), 1);
  payload.copy(frame, OUTPUT_FRAME_HEADER_BYTES);
  return frame;
}

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
