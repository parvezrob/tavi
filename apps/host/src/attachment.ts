import { randomUUID } from "node:crypto";

export const RESUME_BUFFER_BYTES = 1024 * 1024;
export const DETACHED_RETENTION_MS = 120_000;
const MAX_BUFFER_CHUNK_BYTES = 64 * 1024;
// While a phone is attached, the shared terminal clamps to its small grid.
// The moment it detaches, claim a desktop-scale size so the pane on the Mac
// snaps back immediately instead of staying phone-sized for the whole
// retention window (the multiplexer clamps to the smallest live client).
export const DETACHED_COLUMNS = 250;
export const DETACHED_ROWS = 80;

export interface TerminalProcessLike {
  write(data: string): void;
  resize(cols: number, rows: number): void;
  kill(): void;
  onData(callback: (data: string) => void): unknown;
  onExit(callback: (event: { exitCode: number; signal?: number }) => void): unknown;
}

export interface AttachmentClient {
  onOutput(): void;
  onExit(exit: { code: number; signal?: number }): void;
  onSuperseded(): void;
}

export interface AttachmentOptions {
  retentionMs?: number | undefined;
  maxBufferBytes?: number | undefined;
  onDispose?: (() => void) | undefined;
}

// One pty per session that survives WebSocket drops. Output accumulates in a
// bounded ring tagged with absolute byte offsets so a reconnecting client can
// resume mid-stream; a miss falls back to a fresh attach and a full redraw.
export class TerminalAttachment {
  readonly stream = randomUUID();

  private readonly maxBufferBytes: number;
  private readonly onDispose: () => void;
  private readonly retentionMs: number;
  private readonly terminal: TerminalProcessLike;

  private bufferedBytes = 0;
  private chunks: Buffer[] = [];
  private client: AttachmentClient | undefined;
  private disposed = false;
  private exited = false;
  private firstBufferedOffset = 0;
  private nextOffset = 0;
  private retentionTimer: NodeJS.Timeout | undefined;

  constructor(terminal: TerminalProcessLike, options: AttachmentOptions = {}) {
    this.terminal = terminal;
    this.retentionMs = options.retentionMs ?? DETACHED_RETENTION_MS;
    this.maxBufferBytes = options.maxBufferBytes ?? RESUME_BUFFER_BYTES;
    this.onDispose = options.onDispose ?? (() => undefined);

    terminal.onData((data) => {
      this.append(Buffer.from(data, "utf8"));
    });
    terminal.onExit(({ exitCode, signal }) => {
      this.exited = true;
      const client = this.client;
      this.dispose();
      client?.onExit({ code: exitCode, ...(typeof signal === "number" ? { signal } : {}) });
    });
    this.scheduleRetention();
  }

  get endOffset(): number {
    return this.nextOffset;
  }

  get startOffset(): number {
    return this.firstBufferedOffset;
  }

  get hasExited(): boolean {
    return this.exited;
  }

  get isDisposed(): boolean {
    return this.disposed;
  }

  contains(offset: number): boolean {
    return offset >= this.firstBufferedOffset && offset <= this.nextOffset;
  }

  read(offset: number, maxBytes: number): Buffer | undefined {
    if (!this.contains(offset)) return undefined;
    const parts: Buffer[] = [];
    let chunkStart = this.firstBufferedOffset;
    let remaining = maxBytes;
    for (const chunk of this.chunks) {
      if (remaining === 0) break;
      const chunkEnd = chunkStart + chunk.length;
      if (chunkEnd > offset) {
        const sliceStart = Math.max(0, offset - chunkStart);
        const slice = chunk.subarray(sliceStart, Math.min(chunk.length, sliceStart + remaining));
        parts.push(slice);
        remaining -= slice.length;
      }
      chunkStart = chunkEnd;
    }
    return Buffer.concat(parts);
  }

  claim(client: AttachmentClient): void {
    const previous = this.client;
    this.client = client;
    this.cancelRetention();
    previous?.onSuperseded();
  }

  release(client: AttachmentClient): void {
    if (this.client !== client) return;
    this.client = undefined;
    if (this.disposed) return;
    this.scheduleRetention();
    try {
      this.terminal.resize(DETACHED_COLUMNS, DETACHED_ROWS);
    } catch {
      // The pty may already be gone; releasing must not throw.
    }
  }

  write(data: string): void {
    if (this.disposed) return;
    this.terminal.write(data);
  }

  resize(cols: number, rows: number): void {
    if (this.disposed) return;
    this.terminal.resize(cols, rows);
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.cancelRetention();
    this.client = undefined;
    if (!this.exited) {
      try {
        this.terminal.kill();
      } catch {
        // The pty may already be gone; disposal must not throw.
      }
    }
    this.chunks = [];
    this.bufferedBytes = 0;
    this.firstBufferedOffset = this.nextOffset;
    this.onDispose();
  }

  private append(data: Buffer): void {
    if (this.disposed || data.length === 0) return;
    // Bounded chunk size keeps ring trimming granular even for burst output.
    for (let start = 0; start < data.length; start += MAX_BUFFER_CHUNK_BYTES) {
      this.chunks.push(data.subarray(start, Math.min(data.length, start + MAX_BUFFER_CHUNK_BYTES)));
    }
    this.nextOffset += data.length;
    this.bufferedBytes += data.length;
    while (this.bufferedBytes > this.maxBufferBytes && this.chunks.length > 0) {
      const removed = this.chunks.shift();
      if (!removed) break;
      this.bufferedBytes -= removed.length;
      this.firstBufferedOffset += removed.length;
    }
    this.client?.onOutput();
  }

  private scheduleRetention(): void {
    this.cancelRetention();
    this.retentionTimer = setTimeout(() => {
      this.dispose();
    }, this.retentionMs);
    this.retentionTimer.unref?.();
  }

  private cancelRetention(): void {
    if (this.retentionTimer) clearTimeout(this.retentionTimer);
    this.retentionTimer = undefined;
  }
}

export class AttachmentStore {
  private readonly attachments = new Map<string, TerminalAttachment>();
  private readonly options: Pick<AttachmentOptions, "retentionMs" | "maxBufferBytes">;

  constructor(options: Pick<AttachmentOptions, "retentionMs" | "maxBufferBytes"> = {}) {
    this.options = options;
  }

  get(id: string): TerminalAttachment | undefined {
    return this.attachments.get(id);
  }

  create(id: string, terminal: TerminalProcessLike): TerminalAttachment {
    this.get(id)?.dispose();
    const attachment = new TerminalAttachment(terminal, {
      ...this.options,
      onDispose: () => {
        if (this.attachments.get(id) === attachment) this.attachments.delete(id);
      },
    });
    this.attachments.set(id, attachment);
    return attachment;
  }

  disposeAll(): void {
    for (const attachment of [...this.attachments.values()]) {
      attachment.dispose();
    }
  }
}
