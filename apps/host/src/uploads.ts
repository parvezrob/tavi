import { promises as fs, type Stats } from "node:fs";
import type { IncomingMessage } from "node:http";
import path from "node:path";

import { resolveWithinRoots } from "./files.js";
import { git } from "./git-exec.js";

// An image the phone attaches to a message (#88): saved into the agent's
// own folder under `.tavi/uploads/` so the agent can read it by path —
// Claude Code and friends open an image when the prompt names one. The
// folder lives inside the roots like everything the phone may touch, is
// kept out of git through `.git/info/exclude`, and is swept of files older
// than a week on every upload. Images only, 10 MB at most.

export const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;
const RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
const UPLOADS_FOLDER = path.join(".tavi", "uploads");
const EXCLUDE_LINE = ".tavi/uploads/";

const IMAGE_TYPES: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/gif": "gif",
  "image/webp": "webp",
  "image/heic": "heic",
};

export type UploadResult =
  | { ok: true; path: string; bytes: number }
  | { ok: false; status: 400 | 403 | 404 | 413 | 415; error: string; outsideRoots?: true };

export function extensionFor(contentType: string | undefined): string | null {
  const bare = (contentType ?? "").split(";")[0]?.trim().toLowerCase() ?? "";
  return IMAGE_TYPES[bare] ?? null;
}

// Reads the raw body up to the cap; one byte over is a 413, not a
// truncated file on disk.
export async function readUploadBody(request: IncomingMessage, maxBytes = MAX_UPLOAD_BYTES): Promise<Buffer | null> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buffer.length;
    if (size > maxBytes) return null;
    chunks.push(buffer);
  }
  return Buffer.concat(chunks);
}

export async function saveUpload(options: {
  cwd: string;
  roots: readonly string[];
  contentType: string | undefined;
  body: Buffer;
  now?: Date;
}): Promise<UploadResult> {
  const extension = extensionFor(options.contentType);
  if (!extension) return { ok: false, status: 415, error: "Only images can be attached (JPEG, PNG, GIF, WebP, HEIC)." };
  if (options.body.length === 0) return { ok: false, status: 400, error: "The image is empty." };
  if (options.body.length > MAX_UPLOAD_BYTES) return { ok: false, status: 413, error: "Images are limited to 10 MB." };

  const resolved = await resolveWithinRoots(".", options.cwd, options.roots);
  if (!resolved.ok)
    return {
      ok: false,
      status: resolved.status,
      error: resolved.error,
      ...(resolved.outsideRoots ? { outsideRoots: true as const } : {}),
    };
  let folderStat: Stats;
  try {
    folderStat = await fs.stat(resolved.path);
  } catch {
    // Not swallowed: a folder that cannot be stat'd is a 404 with the
    // sentence, and stat's own message would name the path back.
    return { ok: false, status: 404, error: "That folder does not exist on this computer." };
  }
  if (!folderStat.isDirectory()) return { ok: false, status: 400, error: "cwd must be a folder." };

  const folder = path.join(resolved.path, UPLOADS_FOLDER);
  await fs.mkdir(folder, { recursive: true });
  const now = options.now ?? new Date();
  const name = `${stamp(now)}-${Math.random().toString(36).slice(2, 6)}.${extension}`;
  const target = path.join(folder, name);
  await fs.writeFile(target, options.body, { flag: "wx", mode: 0o600 });

  await sweep(folder, now.getTime() - RETENTION_MS, target);
  await excludeFromGit(resolved.path);
  return { ok: true, path: target, bytes: options.body.length };
}

function stamp(date: Date): string {
  const pad = (value: number) => String(value).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`;
}

// Files older than the retention go; the one just written never does.
async function sweep(folder: string, olderThanMs: number, keep: string): Promise<void> {
  let entries: string[];
  try {
    entries = await fs.readdir(folder);
  } catch {
    // The sweep is housekeeping behind a successful upload; a folder that
    // will not list is retried by the next upload's sweep.
    return;
  }
  await Promise.all(
    entries.map(async (entry) => {
      const file = path.join(folder, entry);
      if (file === keep) return;
      try {
        const info = await fs.stat(file);
        if (info.isFile() && info.mtimeMs < olderThanMs) await fs.rm(file);
      } catch {
        // Gone already, or not ours to touch.
      }
    }),
  );
}

// Uploads never land in a commit: `.tavi/uploads/` goes into the
// repository's own exclude file (not `.gitignore`, which is the project's).
// Best effort — a folder that is not a repository simply has no exclude.
async function excludeFromGit(folder: string): Promise<void> {
  let excludePath: string;
  try {
    const { stdout } = await git(folder, ["rev-parse", "--path-format=absolute", "--git-path", "info/exclude"]);
    excludePath = stdout.trim();
    if (!excludePath) return;
  } catch {
    // Not a git repository, so there is no exclude file to write — which
    // this function's own comment already calls best effort.
    return;
  }
  try {
    const existing = await fs.readFile(excludePath, "utf8").catch(() => "");
    if (existing.split("\n").some((line) => line.trim() === EXCLUDE_LINE)) return;
    await fs.mkdir(path.dirname(excludePath), { recursive: true });
    await fs.appendFile(
      excludePath,
      `${existing.length > 0 && !existing.endsWith("\n") ? "\n" : ""}# Tavi: images attached from the phone (#88)\n${EXCLUDE_LINE}\n`,
    );
  } catch {
    // The upload itself succeeded; a missing exclude line is not worth a refusal.
  }
}
