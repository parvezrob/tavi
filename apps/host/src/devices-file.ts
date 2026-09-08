import { closeSync, mkdirSync, openSync, readFileSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import path from "node:path";
import { readStateFile, writeStateFile } from "./state-file.js";

// The two things that sit beside `devices.json`, both there so that file has
// exactly one kind of writer (#68). The lock is what every process changing
// the device list holds across its whole read-modify-write; the last-seen
// stamps are what used to be written *into* the device list by the busiest
// read path in the host, and are now their own file that nothing consults to
// decide access.

// Every process that changes devices.json — the host and each `tavi devices`
// command — takes the lock, so two of them cannot both read [A,B], one write
// [B] and the other write [A,B]. Waiting is bounded: a person is on the other
// end of the CLI, and a lock older than any write could take belonged to a
// process that is gone.
const LOCK_WAIT_MILLISECONDS = 2_000;
const LOCK_RETRY_MILLISECONDS = 20;
const LOCK_STALE_MILLISECONDS = 10_000;
const SEEN_SCHEMA_VERSION = 1;

// The lock wait is a handful of milliseconds in the worst real case and both
// callers are synchronous, so it waits in place rather than colouring `add`
// and `revoke` async for every caller they have.
function sleepSync(milliseconds: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

function isAlreadyExists(error: unknown): boolean {
  return error instanceof Error && "code" in error && error.code === "EEXIST";
}

/**
 * Runs `run` holding the lock for `file`. Read paths must never come here — a
 * phone checking its credential every 2 s must not queue behind
 * `tavi devices revoke`, and it has no reason to: it is not going to write.
 */
export function withDeviceListLock<T>(file: string, run: () => T): T {
  const lock = `${file}.lock`;
  mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const deadline = Date.now() + LOCK_WAIT_MILLISECONDS;
  for (;;) {
    if (takeLock(lock)) {
      try {
        return run();
      } finally {
        releaseLock(lock);
      }
    }
    if (lockIsStale(lock)) {
      // Whoever held this is gone; no write survives ten seconds.
      releaseLock(lock);
      continue;
    }
    if (Date.now() >= deadline) {
      throw new Error(`Tavi could not take the paired-devices lock (${lock}); another Tavi process is holding it.`);
    }
    sleepSync(LOCK_RETRY_MILLISECONDS);
  }
}

function takeLock(lock: string): boolean {
  let descriptor: number | undefined;
  try {
    descriptor = openSync(lock, "wx", 0o600);
    writeFileSync(descriptor, `${process.pid} ${Date.now()}\n`, "utf8");
    return true;
  } catch (error) {
    if (isAlreadyExists(error)) return false;
    throw error;
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

function releaseLock(lock: string): void {
  try {
    unlinkSync(lock);
  } catch {
    // Already gone: taken over as stale, or removed by its owner.
  }
}

// The timestamp the holder wrote, and the file's own mtime when that is
// unreadable — a lock with neither is treated as stale rather than as a
// reason to give up for ever.
function lockIsStale(lock: string): boolean {
  let heldSince: number;
  try {
    const written = Number.parseInt(readFileSync(lock, "utf8").split(" ")[1] ?? "", 10);
    heldSince = Number.isFinite(written) ? written : statSync(lock).mtimeMs;
  } catch {
    return true;
  }
  return Date.now() - heldSince > LOCK_STALE_MILLISECONDS;
}

/** Device id → ISO timestamp. Empty for a file that is absent or unreadable. */
export function readLastSeen(file: string): Record<string, string> {
  const read = readStateFile(file);
  if (read.status !== "ok") return {};
  const stored = read.value as { version?: unknown; seen?: unknown };
  if (stored?.version !== SEEN_SCHEMA_VERSION || typeof stored.seen !== "object" || stored.seen === null) return {};
  const seen: Record<string, string> = {};
  for (const [id, at] of Object.entries(stored.seen as Record<string, unknown>)) {
    if (typeof at === "string") seen[id] = at;
  }
  return seen;
}

export function writeLastSeen(file: string, seen: Record<string, string>): void {
  writeStateFile(file, { version: SEEN_SCHEMA_VERSION, seen });
}
