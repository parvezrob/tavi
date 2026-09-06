import { randomUUID } from "node:crypto";

const RESUME_BUFFER_BYTES = 1024 * 1024;
const DETACHED_RETENTION_MS = 120_000;
// How long a released pty keeps the phone's size before it is handed back
// to the desktop (#63). A reconnect flap — network blip, path change, a busy
// host — re-claims within a few seconds; resizing wide and back in between
// made the agent's TUI redraw at 174 columns and reflow at 41, garbling the
// transcript the person was reading. Longer than the phone's reconnect
// backoff, far shorter than retention.
const DETACH_GRACE_MS = 8_000;
const MAX_BUFFER_CHUNK_BYTES = 64 * 1024;

export interface TerminalSize {
  cols: number;
  rows: number;
}

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
  // The size to hand the terminal back to when the phone detaches: what the
  // desktop is actually displaying (#44). herdr keeps the last size it was
  // told, so an oversized guess would leave the Mac cropped; resolving
  // `undefined` — or having no way to ask — leaves the size alone (small but
  // complete beats large and cropped).
  detachedSize?: (() => Promise<TerminalSize | undefined>) | undefined;
  // How long after release to wait before applying `detachedSize`; a claim
  // inside the window cancels it (#63).
  detachGraceMs?: number | undefined;
}

// One pty per session that survives WebSocket drops. Output accumulates in a
// bounded ring tagged with absolute byte offsets so a reconnecting client can
// resume mid-stream; a miss falls back to a fresh attach and a full redraw.
export class TerminalAttachment {
  readonly stream = randomUUID();

  private readonly maxBufferBytes: number;
  private readonly onDispose: () => void;
  private readonly detachedSize: (() => Promise<TerminalSize | undefined>) | undefined;
  private readonly detachGraceMs: number;
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
  private detachTimer: NodeJS.Timeout | undefined;

  constructor(terminal: TerminalProcessLike, options: AttachmentOptions = {}) {
    this.terminal = terminal;
    this.retentionMs = options.retentionMs ?? DETACHED_RETENTION_MS;
    this.maxBufferBytes = options.maxBufferBytes ?? RESUME_BUFFER_BYTES;
    this.onDispose = options.onDispose ?? (() => undefined);
    this.detachedSize = options.detachedSize;
    this.detachGraceMs = options.detachGraceMs ?? DETACH_GRACE_MS;

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
    // A re-claim inside the grace window is a flap, not a detach: the pty
    // keeps the phone's size and the desktop never sees a resize.
    this.cancelDetach();
    previous?.onSuperseded();
  }

  release(client: AttachmentClient): void {
    if (this.client !== client) return;
    this.client = undefined;
    if (this.disposed) return;
    this.scheduleRetention();
    if (!this.detachedSize) return;
    this.cancelDetach();
    this.detachTimer = setTimeout(() => {
      this.detachTimer = undefined;
      this.handBackToDesktop();
    }, this.detachGraceMs);
    this.detachTimer.unref?.();
  }

  private handBackToDesktop(): void {
    if (!this.detachedSize || this.client !== undefined || this.disposed) return;
    void this.detachedSize().then((size) => {
      // A phone may have re-claimed while herdr was asked; its size then wins.
      if (size && this.client === undefined && !this.disposed) this.safeResize(size);
    });
  }

  private cancelDetach(): void {
    if (this.detachTimer) clearTimeout(this.detachTimer);
    this.detachTimer = undefined;
  }

  private safeResize(size: TerminalSize): void {
    try {
      this.terminal.resize(size.cols, size.rows);
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

  // Disposing an attachment out from under its client is a takeover, not a
  // drop: a client that is not told keeps a live-looking frozen terminal (#108).
  supersede(): void {
    const previous = this.client;
    this.client = undefined;
    this.dispose();
    previous?.onSuperseded();
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.cancelRetention();
    this.cancelDetach();
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
  private readonly options: Pick<AttachmentOptions, "retentionMs" | "maxBufferBytes" | "detachGraceMs">;

  constructor(options: Pick<AttachmentOptions, "retentionMs" | "maxBufferBytes" | "detachGraceMs"> = {}) {
    this.options = options;
  }

  get(id: string): TerminalAttachment | undefined {
    return this.attachments.get(id);
  }

  create(
    id: string,
    terminal: TerminalProcessLike,
    options: Pick<AttachmentOptions, "detachedSize"> = {},
  ): TerminalAttachment {
    this.get(id)?.supersede();
    const attachment = new TerminalAttachment(terminal, {
      ...this.options,
      ...options,
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
