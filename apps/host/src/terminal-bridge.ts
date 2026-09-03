import type * as pty from "node-pty";
import type { RawData, WebSocket } from "ws";
import type { AttachmentClient, AttachmentStore } from "./attachment.js";
import type { HostConfig } from "./config.js";
import type { TerminalSize } from "./herdr.js";
import {
  chunkTerminalOutput,
  encodeOutputFrame,
  MAX_OUTPUT_PAYLOAD_BYTES,
  MAX_TERMINAL_FRAME_BYTES,
  parseClientTerminalMessage,
} from "./protocol.js";
import type { AttachCommand, ServerTerminalMessage } from "./types.js";
import { clamp } from "./validation.js";

// Small buffers on purpose: when the phone falls behind, pausing the pty
// quickly means the pane holds fresh frames instead of the connection
// replaying a large backlog of stale screen paints.
const WEBSOCKET_HIGH_WATER_BYTES = 64 * 1024;
const WEBSOCKET_LOW_WATER_BYTES = 16 * 1024;
const MAX_PENDING_OUTPUT_BYTES = 256 * 1024;
const BACKPRESSURE_POLL_MILLISECONDS = 25;

export interface TerminalResumeRequest {
  stream: string;
  offset: number;
}

export function parseResumeRequest(url: URL): TerminalResumeRequest | undefined {
  const stream = url.searchParams.get("stream");
  const resume = url.searchParams.get("resume");
  if (!stream || !resume) return undefined;
  if (!/^[A-Za-z0-9-]{1,64}$/.test(stream) || !/^\d{1,15}$/.test(resume)) return undefined;
  return { stream, offset: Number.parseInt(resume, 10) };
}

export interface TerminalTarget {
  key: string;
  spawn: () => pty.IPty;
  // What the desktop shows for this pane; handed back on phone detach (#44).
  detachedSize?: () => Promise<TerminalSize | undefined>;
}

export function spawnAttachmentTerminal(
  attach: AttachCommand,
  config: HostConfig,
  spawnTerminal: typeof pty.spawn,
): pty.IPty {
  const env = { ...process.env };
  delete env.npm_config_prefix;
  delete env.NPM_CONFIG_PREFIX;
  // Flow control stays off so a stray XOFF (Ctrl-S) can never freeze output.
  return spawnTerminal(attach.bin, attach.args, {
    name: "xterm-256color",
    cols: 100,
    rows: 30,
    cwd: config.stateDir,
    env: {
      ...env,
      TERM: "xterm-256color",
      COLORTERM: "truecolor",
    },
  });
}

export function bridgeTerminalV2(
  websocket: WebSocket,
  target: TerminalTarget,
  attachments: AttachmentStore,
  resume?: TerminalResumeRequest,
): void {
  let attachment = attachments.get(target.key);
  let cursor: number;
  let resumed = false;

  if (
    attachment &&
    !attachment.hasExited &&
    resume &&
    resume.stream === attachment.stream &&
    attachment.contains(resume.offset)
  ) {
    cursor = resume.offset;
    resumed = true;
  } else {
    // A resume miss (no attachment, epoch mismatch, or the offset already
    // trimmed out of the ring) gets a fresh attach: herdr repaints the whole
    // pane, so the client is complete again without replay.
    attachment?.dispose();
    attachment = attachments.create(target.key, target.spawn(), {
      detachedSize: target.detachedSize,
    });
    cursor = attachment.endOffset;
  }
  const active = attachment;

  let flushTimer: NodeJS.Timeout | undefined;
  const clearFlushTimer = () => {
    if (flushTimer) clearInterval(flushTimer);
    flushTimer = undefined;
  };
  const flush = () => {
    while (
      websocket.readyState === websocket.OPEN &&
      cursor < active.endOffset &&
      websocket.bufferedAmount <= WEBSOCKET_HIGH_WATER_BYTES
    ) {
      const payload = active.read(cursor, MAX_OUTPUT_PAYLOAD_BYTES);
      if (payload === undefined) {
        // The client fell more than the resume buffer behind; a fresh attach
        // with a full redraw beats replaying that much stale screen paint.
        sendTerminal(websocket, {
          type: "error",
          message: "Terminal output overran the resume buffer.",
        });
        websocket.close(1011, "resume buffer overrun");
        return;
      }
      if (payload.length === 0) return;
      websocket.send(encodeOutputFrame(cursor, payload));
      cursor += payload.length;
    }
    if (cursor < active.endOffset && websocket.readyState === websocket.OPEN) {
      if (flushTimer) return;
      flushTimer = setInterval(() => {
        if (websocket.readyState !== websocket.OPEN) {
          clearFlushTimer();
          return;
        }
        if (websocket.bufferedAmount > WEBSOCKET_LOW_WATER_BYTES) return;
        clearFlushTimer();
        flush();
      }, BACKPRESSURE_POLL_MILLISECONDS);
    } else {
      clearFlushTimer();
    }
  };

  const client: AttachmentClient = {
    onOutput: flush,
    onExit: (exit) => {
      clearFlushTimer();
      sendTerminal(websocket, {
        type: "exit",
        code: exit.code,
        ...(typeof exit.signal === "number" ? { signal: exit.signal } : {}),
      });
      websocket.close(1000, "terminal exited");
    },
    onSuperseded: () => {
      clearFlushTimer();
      sendTerminal(websocket, { type: "error", message: "Another connection took over this terminal." });
      websocket.close(1000, "superseded");
    },
  };

  active.claim(client);
  sendTerminal(websocket, { type: "ready", stream: active.stream, offset: cursor, resumed });
  flush();

  websocket.on("message", (raw: RawData, isBinary: boolean) => {
    if (isBinary) {
      sendTerminal(websocket, { type: "error", message: "Binary terminal messages are unsupported." });
      websocket.close(1003, "text frames required");
      return;
    }
    if (Buffer.byteLength(raw.toString()) > MAX_TERMINAL_FRAME_BYTES) {
      sendTerminal(websocket, { type: "error", message: "Terminal message is too large." });
      websocket.close(1009, "message too large");
      return;
    }
    try {
      const message = parseClientTerminalMessage(JSON.parse(raw.toString()));
      if (!message) {
        sendTerminal(websocket, { type: "error", message: "Invalid terminal message." });
        return;
      }
      switch (message.type) {
        case "input":
          active.write(message.data);
          break;
        case "resize":
          active.resize(clamp(message.cols, 20, 400), clamp(message.rows, 5, 200));
          break;
        case "ping":
          sendTerminal(websocket, { type: "pong", id: message.id });
          break;
      }
    } catch {
      sendTerminal(websocket, { type: "error", message: "Invalid terminal message." });
    }
  });

  const releaseClient = () => {
    clearFlushTimer();
    active.release(client);
  };
  websocket.once("close", releaseClient);
  websocket.once("error", releaseClient);
}

export function bridgeTerminal(websocket: WebSocket, target: TerminalTarget): void {
  const terminal = target.spawn();

  let attachmentClosed = false;
  let terminalPaused = false;
  let pendingOutputBytes = 0;
  let backpressureTimer: NodeJS.Timeout | undefined;
  const pendingOutputChunks: string[] = [];

  const clearBackpressureTimer = () => {
    if (backpressureTimer) clearInterval(backpressureTimer);
    backpressureTimer = undefined;
  };
  const killAttachment = () => {
    clearBackpressureTimer();
    if (attachmentClosed) return;
    attachmentClosed = true;
    terminal.kill();
  };
  const pauseTerminal = () => {
    if (!terminalPaused) terminal.pause();
    terminalPaused = true;
    if (backpressureTimer) return;
    backpressureTimer = setInterval(() => {
      if (websocket.readyState !== websocket.OPEN) {
        clearBackpressureTimer();
        return;
      }
      if (websocket.bufferedAmount > WEBSOCKET_LOW_WATER_BYTES) return;
      flushOutput();
      if (pendingOutputChunks.length === 0 && websocket.bufferedAmount <= WEBSOCKET_LOW_WATER_BYTES) {
        terminal.resume();
        terminalPaused = false;
        clearBackpressureTimer();
      }
    }, BACKPRESSURE_POLL_MILLISECONDS);
  };
  const flushOutput = () => {
    while (
      pendingOutputChunks.length > 0 &&
      websocket.readyState === websocket.OPEN &&
      websocket.bufferedAmount <= WEBSOCKET_HIGH_WATER_BYTES
    ) {
      const chunk = pendingOutputChunks.shift();
      if (chunk === undefined) break;
      pendingOutputBytes -= Buffer.byteLength(chunk);
      if (!sendTerminal(websocket, { type: "output", data: chunk })) break;
    }
    if (pendingOutputChunks.length > 0 || websocket.bufferedAmount > WEBSOCKET_HIGH_WATER_BYTES) {
      pauseTerminal();
    }
  };

  sendTerminal(websocket, { type: "ready" });
  terminal.onData((data) => {
    const dataBytes = Buffer.byteLength(data);
    if (dataBytes > MAX_PENDING_OUTPUT_BYTES - pendingOutputBytes) {
      sendTerminal(websocket, {
        type: "error",
        message: "Terminal output exceeded the connection safety buffer.",
      });
      websocket.close(1013, "terminal output overloaded");
      killAttachment();
      return;
    }
    pendingOutputChunks.push(...chunkTerminalOutput(data));
    pendingOutputBytes += dataBytes;
    flushOutput();
  });
  terminal.onExit(({ exitCode, signal }) => {
    if (attachmentClosed) return;
    attachmentClosed = true;
    clearBackpressureTimer();
    sendTerminal(websocket, {
      type: "exit",
      code: exitCode,
      ...(typeof signal === "number" ? { signal } : {}),
    });
    websocket.close(1000, "terminal exited");
  });

  websocket.on("message", (raw: RawData, isBinary: boolean) => {
    if (isBinary) {
      sendTerminal(websocket, { type: "error", message: "Binary terminal messages are unsupported." });
      websocket.close(1003, "text frames required");
      return;
    }
    if (Buffer.byteLength(raw.toString()) > MAX_TERMINAL_FRAME_BYTES) {
      sendTerminal(websocket, { type: "error", message: "Terminal message is too large." });
      websocket.close(1009, "message too large");
      return;
    }
    try {
      const message = parseClientTerminalMessage(JSON.parse(raw.toString()));
      if (!message) {
        sendTerminal(websocket, { type: "error", message: "Invalid terminal message." });
        return;
      }
      switch (message.type) {
        case "input":
          terminal.write(message.data);
          break;
        case "resize":
          terminal.resize(clamp(message.cols, 20, 400), clamp(message.rows, 5, 200));
          break;
        case "ping":
          sendTerminal(websocket, { type: "pong", id: message.id });
          break;
      }
    } catch {
      sendTerminal(websocket, { type: "error", message: "Invalid terminal message." });
    }
  });

  websocket.once("close", killAttachment);
  websocket.once("error", killAttachment);
}

export function sendTerminal(websocket: WebSocket, message: ServerTerminalMessage): boolean {
  if (websocket.readyState !== websocket.OPEN) return false;
  const frame = JSON.stringify(message);
  if (Buffer.byteLength(frame) > MAX_TERMINAL_FRAME_BYTES) {
    websocket.close(1011, "server frame too large");
    return false;
  }
  websocket.send(frame);
  return true;
}
