import {
  closeSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { randomBytes } from "node:crypto";
import path from "node:path";

// Owner-only JSON files under the host state directory, shared by the
// recent-projects list and the paired-device registry. Same posture as the
// pairing file (#35): directory 0700, file 0600, contents flushed and swapped
// in atomically so a crashing process cannot leave a half-written file. The
// directory itself is not synced, so a power loss can still lose the newest
// write — acceptable for these, which are re-creatable state, not records.

export type StateFileRead =
  | { status: "missing" }
  | { status: "ok"; value: unknown }
  | { status: "unreadable"; reason: string };

export function readStateFile(file: string): StateFileRead {
  try {
    return { status: "ok", value: JSON.parse(readFileSync(file, "utf8")) as unknown };
  } catch (error) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") return { status: "missing" };
    return { status: "unreadable", reason: error instanceof Error ? error.message : String(error) };
  }
}

/**
 * Writes `value` to `file` through a temporary file and one atomic rename.
 *
 * `beforeSwap` is the last thing consulted before the rename, and returning
 * false abandons the write (the temporary file is removed, the target is left
 * alone). It is how a caller doing a read-modify-write can refuse to swap in a
 * list computed from a version of the file somebody else has since replaced.
 * Returns whether the swap happened.
 */
export function writeStateFile(file: string, value: unknown, beforeSwap?: () => boolean): boolean {
  const directory = path.dirname(file);
  const temporary = path.join(
    directory,
    `.${path.basename(file)}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`,
  );
  let descriptor: number | undefined;
  try {
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    descriptor = openSync(temporary, "wx", 0o600);
    writeFileSync(descriptor, `${JSON.stringify(value, null, 2)}\n`, "utf8");
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    if (beforeSwap && !beforeSwap()) return false;
    renameSync(temporary, file);
    return true;
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
    try {
      unlinkSync(temporary);
    } catch {
      // Already gone: either the swap succeeded or it was never created.
    }
  }
}
