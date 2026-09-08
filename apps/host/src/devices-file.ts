import { readStateFile, writeStateFile } from "./state-file.js";

// The last-seen stamps that sit beside `devices.json` (#68). They used to be
// written *into* the device list by the busiest read path in the host, which
// made every connecting phone a writer of the file that decides access. They
// are their own file now, and nothing consults them to decide anything: a
// stamp that is missing, stale or unwritable costs a person one column in
// `tavi devices list` and costs a phone nothing at all.
//
// There is deliberately no lock beside `devices.json`. Once last-seen moved
// out, the only writers left were `add` and `revoke` — rare, human-driven, and
// already guarded by the signature check `DeviceRegistry` makes immediately
// before its atomic rename. A lock file could only add failure modes of its
// own (a holder that died, an unreadable lock, a blocked event loop, an
// ownerless lock left by a failed write); the compare-and-swap has none.

const SEEN_SCHEMA_VERSION = 1;

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
