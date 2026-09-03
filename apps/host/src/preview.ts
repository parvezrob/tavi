import { createHash, randomBytes } from "node:crypto";
import { connect } from "node:net";

// Private dev-server preview (#58). An agent starts something on
// `localhost:<port>` on this computer; the phone shows it in a WebKit view
// without the server being started any differently and without anyone but
// the paired phone being able to open it.
//
// Shape: one *door*. Tailscale Serve publishes `https://<name>.ts.net:8443`
// once and forever → this process's loopback listener (`preview-door.ts`).
// The door forwards nothing on its own. A request gets through only with a
// *ticket* cookie the phone obtained over the bearer-authenticated API
// (`PreviewRegistry.open` below), and the ticket names the loopback port it
// may reach. So: no per-preview Tailscale state to reap, no path prefix to
// break absolute asset URLs, and a ticket that dies when the sheet closes,
// when the phone goes quiet, or when this process restarts.
//
// This file is the registry — the security invariant "a preview reaches
// exactly one loopback port, for the one device that opened it". The door
// is `preview-door.ts`, finding dev servers is `preview-servers.ts` (#98).

export const TICKET_COOKIE = "tavi_preview";
// A preview lives while the phone keeps it alive — a heartbeat or any
// traffic through the door. This is only the net under a killed app.
const PREVIEW_GRACE_MS = 120_000;
const SWEEP_MS = 15_000;
// How long a dev server gets to accept a connection at all before the
// registry calls the port dead.
const PROBE_TIMEOUT_MS = 1_500;
const MAX_PREVIEWS = 32;

export type LoopbackAddress = "127.0.0.1" | "::1";

export interface Preview {
  id: string;
  deviceId: string;
  port: number;
  // Which loopback the server actually answers on; `localhost` may resolve
  // to ::1 on the machine that started it (Vite does this on macOS).
  address: LoopbackAddress;
  cwd: string;
  openedAt: number;
  lastSeenAt: number;
}

export interface OpenedPreview {
  preview: Preview;
  // Returned exactly once; the registry keeps only its hash.
  ticket: string;
}

export type OpenResult = { ok: true; opened: OpenedPreview } | { ok: false; status: 400 | 409 | 429; error: string };

export interface PreviewRegistryOptions {
  now?: () => number;
  graceMs?: number;
  probe?: (port: number) => Promise<LoopbackAddress | undefined>;
}

export class PreviewRegistry {
  private readonly byTicketHash = new Map<string, Preview>();
  private readonly now: () => number;
  private readonly graceMs: number;
  private readonly probe: (port: number) => Promise<LoopbackAddress | undefined>;
  private sweeper: NodeJS.Timeout | undefined;

  constructor(options: PreviewRegistryOptions = {}) {
    this.now = options.now ?? (() => Date.now());
    this.graceMs = options.graceMs ?? PREVIEW_GRACE_MS;
    this.probe = options.probe ?? probeLoopback;
  }

  start(): void {
    if (this.sweeper) return;
    this.sweeper = setInterval(() => this.sweep(), SWEEP_MS);
    this.sweeper.unref?.();
  }

  stop(): void {
    if (this.sweeper) clearInterval(this.sweeper);
    this.sweeper = undefined;
    this.byTicketHash.clear();
  }

  async open(input: { deviceId: string; port: unknown; cwd: string }): Promise<OpenResult> {
    const port = validPort(input.port);
    if (port === undefined) return { ok: false, status: 400, error: "port must be a number between 1 and 65535." };
    this.sweep();
    if (this.byTicketHash.size >= MAX_PREVIEWS) {
      return { ok: false, status: 429, error: "Too many previews are open on this computer. Close one first." };
    }
    const address = await this.probe(port);
    if (!address) {
      return { ok: false, status: 409, error: `Nothing is listening on localhost:${port} on this computer.` };
    }
    const ticket = randomBytes(32).toString("base64url");
    const at = this.now();
    const preview: Preview = {
      id: randomBytes(8).toString("hex"),
      deviceId: input.deviceId,
      port,
      address,
      cwd: input.cwd,
      openedAt: at,
      lastSeenAt: at,
    };
    this.byTicketHash.set(hashTicket(ticket), preview);
    return { ok: true, opened: { preview, ticket } };
  }

  // The door's lookup: a live preview for this ticket, its clock refreshed.
  admit(ticket: string | undefined): Preview | undefined {
    if (!ticket || ticket.length > 128) return undefined;
    const preview = this.byTicketHash.get(hashTicket(ticket));
    if (!preview) return undefined;
    if (this.expired(preview)) {
      this.byTicketHash.delete(hashTicket(ticket));
      return undefined;
    }
    preview.lastSeenAt = this.now();
    return preview;
  }

  // The phone's heartbeat. Only the device that opened a preview may touch it.
  touch(id: string, deviceId: string): Preview | undefined {
    const preview = this.find(id, deviceId);
    if (!preview) return undefined;
    preview.lastSeenAt = this.now();
    return preview;
  }

  close(id: string, deviceId: string): boolean {
    for (const [hash, preview] of this.byTicketHash) {
      if (preview.id === id && preview.deviceId === deviceId) {
        this.byTicketHash.delete(hash);
        return true;
      }
    }
    return false;
  }

  list(deviceId: string): Preview[] {
    this.sweep();
    return [...this.byTicketHash.values()].filter((preview) => preview.deviceId === deviceId);
  }

  // Is the server behind a preview still there? (The phone's heartbeat asks.)
  async listening(preview: Preview): Promise<boolean> {
    return (await this.probe(preview.port)) !== undefined;
  }

  get size(): number {
    return this.byTicketHash.size;
  }

  private find(id: string, deviceId: string): Preview | undefined {
    this.sweep();
    for (const preview of this.byTicketHash.values()) {
      if (preview.id === id && preview.deviceId === deviceId) return preview;
    }
    return undefined;
  }

  private expired(preview: Preview): boolean {
    return this.now() - preview.lastSeenAt > this.graceMs;
  }

  private sweep(): void {
    for (const [hash, preview] of this.byTicketHash) {
      if (this.expired(preview)) this.byTicketHash.delete(hash);
    }
  }
}

function hashTicket(ticket: string): string {
  return createHash("sha256").update(ticket).digest("hex");
}

export function validPort(value: unknown): number | undefined {
  const port = typeof value === "string" ? Number.parseInt(value, 10) : value;
  return typeof port === "number" && Number.isInteger(port) && port >= 1 && port <= 65_535 ? port : undefined;
}

// Is anything accepting connections on this port, on which loopback?
async function probeLoopback(port: number): Promise<LoopbackAddress | undefined> {
  for (const address of ["127.0.0.1", "::1"] as const) {
    if (await accepts(address, port)) return address;
  }
  return undefined;
}

function accepts(address: LoopbackAddress, port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = connect({ host: address, port });
    const done = (ok: boolean) => {
      socket.destroy();
      resolve(ok);
    };
    socket.setTimeout(PROBE_TIMEOUT_MS, () => done(false));
    socket.once("connect", () => done(true));
    socket.once("error", () => done(false));
  });
}
