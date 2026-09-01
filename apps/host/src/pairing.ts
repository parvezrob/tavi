import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import path from "node:path";
import { readStateFile, writeStateFile } from "./state-file.js";

// Pairing (#45) and per-device credentials (#46). A phone never sees the
// host's shared token: `tavi pair` mints a single-use, short-lived secret,
// the phone redeems it once, and gets a credential of its own that can be
// revoked on the host without touching any other phone.

const DEVICES_FILE_NAME = "devices.json";
const IDENTITY_FILE_NAME = "identity.json";
const DEVICES_SCHEMA_VERSION = 1;
const IDENTITY_SCHEMA_VERSION = 1;
// Long enough to walk to the phone; short enough that a QR left on a
// screen is not a standing invitation.
export const PAIRING_SECRET_TTL_MILLISECONDS = 5 * 60 * 1_000;
// A pairing session is one person at one screen; more than a handful of
// live secrets means something is generating them, not someone.
const MAX_PENDING_SECRETS = 5;
// Last-seen is informational; writing it on every request would turn each
// API call into a disk write.
const LAST_SEEN_WRITE_INTERVAL_MILLISECONDS = 60_000;

export interface PairedDevice {
  id: string;
  name: string;
  pairedAt: string;
  lastSeenAt?: string;
}

interface StoredDevice extends PairedDevice {
  // sha256 of the credential; the credential itself is only ever on the phone.
  credentialHash: string;
}

export interface HostIdentity {
  // Shown on the host and the phone during pairing so the person can see
  // they are trusting the machine in front of them. Derived from a random
  // per-host key, so two hosts never share one.
  fingerprint: string;
}

export function fingerprintOf(secretKey: Buffer): string {
  const hex = createHash("sha256").update(secretKey).digest("hex").toUpperCase().slice(0, 16);
  return `${hex.slice(0, 4)} ${hex.slice(4, 8)} · ${hex.slice(8, 12)} ${hex.slice(12, 16)}`;
}

function hashCredential(credential: string): string {
  return createHash("sha256").update(credential).digest("hex");
}

function equalHashes(left: string, right: string): boolean {
  const a = Buffer.from(left, "hex");
  const b = Buffer.from(right, "hex");
  return a.length === b.length && timingSafeEqual(a, b);
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

// The persisted set of phones allowed in, and the host's identity key.
export class DeviceRegistry {
  private lastSeenWrittenAt = new Map<string, number>();

  constructor(
    private readonly stateDir: string,
    private readonly now: () => Date = () => new Date(),
    private readonly report: (message: string) => void = (message) => console.error(message),
  ) {}

  identity(): HostIdentity {
    const file = path.join(this.stateDir, IDENTITY_FILE_NAME);
    const read = readStateFile(file);
    if (read.status === "ok") {
      const stored = read.value as { version?: unknown; key?: unknown };
      if (stored?.version === IDENTITY_SCHEMA_VERSION && typeof stored.key === "string") {
        return { fingerprint: fingerprintOf(Buffer.from(stored.key, "base64url")) };
      }
      this.report(`Ignoring an unreadable host identity (${file}); a new one will be created.`);
    } else if (read.status === "unreadable") {
      this.report(`Tavi could not read the host identity (${file}): ${read.reason}. A new one will be created.`);
    }
    const key = randomBytes(32);
    writeStateFile(file, { version: IDENTITY_SCHEMA_VERSION, key: key.toString("base64url") });
    return { fingerprint: fingerprintOf(key) };
  }

  list(): PairedDevice[] {
    return this.load().map(({ credentialHash: _hash, ...device }) => device);
  }

  // The device a credential belongs to, or undefined. Constant-time on the
  // hash so a wrong credential costs the same as a right one.
  authorize(credential: string): PairedDevice | undefined {
    if (!credential) return undefined;
    const hash = hashCredential(credential);
    const devices = this.load();
    const match = devices.find((device) => equalHashes(device.credentialHash, hash));
    if (!match) return undefined;
    this.touch(match, devices);
    const { credentialHash: _hash, ...device } = match;
    return device;
  }

  // Mints and stores a credential for a newly paired phone. The credential
  // is returned exactly once; only its hash is kept.
  add(name: string): { device: PairedDevice; credential: string } {
    const devices = this.load();
    const credential = randomBytes(32).toString("base64url");
    const stored: StoredDevice = {
      id: randomBytes(6).toString("hex"),
      name: name.trim().slice(0, 80) || "iPhone",
      pairedAt: this.now().toISOString(),
      credentialHash: hashCredential(credential),
    };
    this.save([...devices, stored]);
    const { credentialHash: _hash, ...device } = stored;
    return { device, credential };
  }

  // Revoke by id or (unique) name. Returns false if nothing matched, so the
  // CLI can say so instead of pretending.
  revoke(idOrName: string): boolean {
    const devices = this.load();
    const kept = devices.filter((device) => device.id !== idOrName && device.name !== idOrName);
    if (kept.length === devices.length) return false;
    this.save(kept);
    return true;
  }

  private touch(match: StoredDevice, devices: StoredDevice[]): void {
    const nowMs = this.now().getTime();
    const last = this.lastSeenWrittenAt.get(match.id) ?? 0;
    if (nowMs - last < LAST_SEEN_WRITE_INTERVAL_MILLISECONDS) return;
    this.lastSeenWrittenAt.set(match.id, nowMs);
    match.lastSeenAt = new Date(nowMs).toISOString();
    this.save(devices);
  }

  private get file(): string {
    return path.join(this.stateDir, DEVICES_FILE_NAME);
  }

  private load(): StoredDevice[] {
    const read = readStateFile(this.file);
    if (read.status === "missing") return [];
    if (read.status === "unreadable") {
      // Failing closed here would lock every phone out because of a disk
      // hiccup; failing open would let anyone in. Neither: no devices
      // authorize until the file is readable again, and the log says why.
      this.report(`Tavi could not read the paired devices (${this.file}): ${read.reason}. No paired phone can connect until this is fixed.`);
      return [];
    }
    const stored = read.value as { version?: unknown; devices?: unknown };
    if (stored?.version !== DEVICES_SCHEMA_VERSION || !Array.isArray(stored.devices)) {
      this.report(`Ignoring a paired-devices list written by another version (${this.file}): expected version ${DEVICES_SCHEMA_VERSION}.`);
      return [];
    }
    return stored.devices.filter(
      (entry): entry is StoredDevice =>
        typeof entry === "object" &&
        entry !== null &&
        typeof (entry as StoredDevice).id === "string" &&
        typeof (entry as StoredDevice).name === "string" &&
        typeof (entry as StoredDevice).pairedAt === "string" &&
        /^[0-9a-f]{64}$/.test((entry as StoredDevice).credentialHash ?? ""),
    );
  }

  private save(devices: StoredDevice[]): void {
    try {
      writeStateFile(this.file, { version: DEVICES_SCHEMA_VERSION, devices });
    } catch (error) {
      this.report(`Tavi could not save the paired devices (${this.file}): ${describe(error)}.`);
      throw error;
    }
  }
}

// Single-use pairing secrets, in memory only: they are worthless after five
// minutes and a restart should never resurrect one.
export class PairingSessions {
  private readonly pending = new Map<string, number>();

  constructor(private readonly now: () => number = () => Date.now()) {}

  begin(): { secret: string; expiresAt: string } {
    this.expire();
    if (this.pending.size >= MAX_PENDING_SECRETS) {
      throw new Error("Too many pairing codes are already waiting. Use one of them or let them expire.");
    }
    const secret = randomBytes(16).toString("base64url");
    const expiresAtMs = this.now() + PAIRING_SECRET_TTL_MILLISECONDS;
    this.pending.set(secret, expiresAtMs);
    return { secret, expiresAt: new Date(expiresAtMs).toISOString() };
  }

  // True exactly once per live secret.
  redeem(secret: string): boolean {
    this.expire();
    if (!secret || !this.pending.has(secret)) return false;
    this.pending.delete(secret);
    return true;
  }

  get pendingCount(): number {
    this.expire();
    return this.pending.size;
  }

  private expire(): void {
    const nowMs = this.now();
    for (const [secret, expiresAtMs] of this.pending) {
      if (expiresAtMs <= nowMs) this.pending.delete(secret);
    }
  }
}

// What the QR carries. A custom scheme so the phone can own the link, with
// nothing in it that is not needed to reach and verify the host.
export interface PairingPayload {
  url: string;
  secret: string;
  fingerprint: string;
  hostName: string;
}

// encodeURIComponent, not URLSearchParams: the latter writes spaces as "+",
// which Foundation's URL parser on the phone keeps as a literal plus — the
// fingerprint then never matches. "%20" is read the same way everywhere.
export function encodePairingPayload(payload: PairingPayload): string {
  const query = [
    ["u", payload.url],
    ["s", payload.secret],
    ["f", payload.fingerprint],
    ["n", payload.hostName],
  ]
    .map(([key, value]) => `${key}=${encodeURIComponent(value ?? "")}`)
    .join("&");
  return `tavi://pair?${query}`;
}

export function decodePairingPayload(text: string): PairingPayload | undefined {
  let url: URL;
  try {
    url = new URL(text.trim());
  } catch {
    return undefined;
  }
  if (url.protocol !== "tavi:" || url.host !== "pair") return undefined;
  const get = (key: string) => url.searchParams.get(key)?.trim() ?? "";
  const payload = { url: get("u"), secret: get("s"), fingerprint: get("f"), hostName: get("n") };
  return payload.url && payload.secret && payload.fingerprint ? payload : undefined;
}
