import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import path from "node:path";
import { isWithinRoots } from "./projects.js";

// Read-only file access for the phone (#25, #57, #61): what an agent
// changed, what it mentioned, and — as the fallback — what else is in the
// project. Nothing here writes, renames, or deletes, and nothing outside the
// configured roots is reachable by any path. The rule that makes that true
// is `resolveWithinRoots`: resolve against the agent's cwd, follow symlinks
// with realpath, and only then check containment — a symlink that points
// out of a root must be refused after realpath, not before (the #57 trap).

// Text preview cap. A file over this is served up to the cap and marked
// truncated; the phone says so instead of pretending it has the whole file.
export const MAX_TEXT_BYTES = 1024 * 1024;
// Images and PDFs are streamed whole up to this; beyond it the phone gets a
// refusal with the size, not a partial image.
export const MAX_RAW_BYTES = 16 * 1024 * 1024;
const BINARY_SNIFF_BYTES = 8 * 1024;
const MAX_LISTING_ENTRIES = 2_000;
const GIT_TIMEOUT_MS = 5_000;

export type FileResolution =
  | { ok: true; path: string; relativePath: string }
  | { ok: false; status: 400 | 403 | 404; error: string; outsideRoots?: true };

// `candidate` is what the phone has: an absolute path, or one relative to
// the agent's `cwd`. The result is the real, symlink-free path inside a
// root, or a refusal the client can show as-is.
export async function resolveWithinRoots(
  candidate: string,
  cwd: string,
  roots: readonly string[],
): Promise<FileResolution> {
  const trimmed = candidate.trim();
  if (!trimmed || trimmed.includes("\0") || trimmed.length > 4_096) {
    return { ok: false, status: 400, error: "path must be a file path." };
  }
  if (!path.isAbsolute(cwd)) {
    return { ok: false, status: 400, error: "cwd must be an absolute path." };
  }
  const joined = path.isAbsolute(trimmed) ? trimmed : path.resolve(cwd, trimmed);
  let real: string;
  try {
    real = await fs.realpath(joined);
  } catch {
    // Missing. Where it *would* be is still decided after symlinks: the
    // deepest existing ancestor is realpath'd and the rest re-joined, so a
    // missing name under a symlinked folder is judged by where the symlink
    // points. Inside a root: a plain 404. Outside: say so, and say nothing
    // else about whether anything exists there.
    const wouldBe = await realpathOfNearestAncestor(joined);
    if (!(await containedAfterRealpath(wouldBe, roots))) {
      return { ok: false, status: 403, error: "That file is outside your project folders.", outsideRoots: true };
    }
    return { ok: false, status: 404, error: "No such file." };
  }
  if (!(await containedAfterRealpath(real, roots))) {
    return { ok: false, status: 403, error: "That file is outside your project folders.", outsideRoots: true };
  }
  if (real.split(path.sep).includes(".git")) {
    // The repository's own database is not project content; a phone never
    // needs to read objects or refs, and listing them is noise at best.
    return { ok: false, status: 403, error: "Git's own files are not shown." };
  }
  return { ok: true, path: real, relativePath: await relativeToCwd(real, cwd) };
}

async function realpathOfNearestAncestor(target: string): Promise<string> {
  let head = target;
  const tail: string[] = [];
  while (true) {
    try {
      return path.join(await fs.realpath(head), ...tail);
    } catch {
      const parent = path.dirname(head);
      if (parent === head) return target;
      tail.unshift(path.basename(head));
      head = parent;
    }
  }
}

// Roots may themselves be symlinks (macOS /tmp → /private/tmp), so both
// sides of the comparison are realpath'd. A root that does not exist
// contains nothing.
async function containedAfterRealpath(real: string, roots: readonly string[]): Promise<boolean> {
  const realRoots: string[] = [];
  for (const root of roots) {
    try {
      realRoots.push(await fs.realpath(root));
    } catch {
      // Not on disk: it contains nothing.
    }
  }
  return isWithinRoots(real, realRoots);
}

// Relative to the agent's cwd when the file is under it, else absolute —
// both sides realpath'd, or macOS's /var → /private/var would make every
// path under a temp folder look foreign.
async function relativeToCwd(target: string, cwd: string): Promise<string> {
  let base = cwd;
  try {
    base = await fs.realpath(cwd);
  } catch {
    // A cwd that is gone: the absolute path is the honest answer.
  }
  const relative = path.relative(base, target);
  return relative.startsWith("..") || path.isAbsolute(relative) ? target : relative;
}

// Files whose contents are credentials by convention. The pairing token
// already grants shell access, so this is not a security boundary — it is
// the redaction rule #25 asked for: a phone preview never shows a secret by
// accident, in a file or in a diff. Refused by name, and the phone says so.
export function looksLikeASecret(filePath: string): boolean {
  const name = path.basename(filePath).toLowerCase();
  if (name === ".env" || name.startsWith(".env.")) return true;
  if (name.endsWith(".pem") || name.endsWith(".key") || name.endsWith(".p12") || name.endsWith(".pfx")) return true;
  if (name.startsWith("id_rsa") || name.startsWith("id_ed25519") || name.startsWith("id_ecdsa")) return true;
  if (name.includes("credentials") || name.includes("secret")) return true;
  if (name === ".npmrc" || name === ".netrc" || name === ".pypirc") return true;
  return false;
}

export interface FileStat {
  path: string;
  name: string;
  kind: "file" | "directory" | "other";
  size: number;
  modifiedAt: string;
  // What the phone can do with it: text preview, image, PDF, or nothing.
  preview: "text" | "image" | "pdf" | "binary" | "secret" | "directory";
  mime: string;
}

export async function statFile(realPath: string): Promise<FileStat> {
  const stat = await fs.stat(realPath);
  const kind = stat.isDirectory() ? "directory" : stat.isFile() ? "file" : "other";
  const mime = mimeFor(realPath);
  let preview: FileStat["preview"] = "binary";
  if (kind === "directory") preview = "directory";
  else if (looksLikeASecret(realPath)) preview = "secret";
  else if (mime.startsWith("image/")) preview = "image";
  else if (mime === "application/pdf") preview = "pdf";
  else if (kind === "file" && (await isText(realPath, stat.size))) preview = "text";
  return {
    path: realPath,
    name: path.basename(realPath),
    kind,
    size: stat.size,
    modifiedAt: stat.mtime.toISOString(),
    preview,
    mime,
  };
}

export interface FileContent {
  path: string;
  size: number;
  mime: string;
  encoding: "utf-8" | "utf-16le" | "utf-16be" | "latin1";
  content: string;
  truncated: boolean;
  lines: number;
}

export type FileContentResult =
  | { ok: true; content: FileContent }
  | { ok: false; status: 400 | 403 | 415; error: string; preview: FileStat["preview"]; size: number; mime: string };

// Text only. Images and PDFs go through `readRaw`; anything else binary is
// refused with its kind so the phone can say "binary file, 2.3 MB" rather
// than render garbage.
export async function readTextContent(realPath: string, maxBytes = MAX_TEXT_BYTES): Promise<FileContentResult> {
  const info = await statFile(realPath);
  if (info.preview === "directory") {
    return { ok: false, status: 400, error: "That is a folder.", preview: info.preview, size: info.size, mime: info.mime };
  }
  if (info.preview === "secret") {
    return { ok: false, status: 403, error: "This file looks like it holds credentials, so Tavi does not show it.", preview: info.preview, size: info.size, mime: info.mime };
  }
  if (info.preview !== "text") {
    return { ok: false, status: 415, error: "This file is not text.", preview: info.preview, size: info.size, mime: info.mime };
  }
  const handle = await fs.open(realPath, "r");
  try {
    const length = Math.min(info.size, maxBytes);
    const buffer = Buffer.alloc(length);
    const { bytesRead } = await handle.read(buffer, 0, length, 0);
    const bytes = buffer.subarray(0, bytesRead);
    const { encoding, text } = decodeText(bytes);
    const truncated = info.size > maxBytes;
    // A truncated read may end mid-character; drop the partial last line so
    // the phone never shows a torn glyph as if it were content.
    const content = truncated ? text.slice(0, Math.max(0, text.lastIndexOf("\n"))) : text;
    return {
      ok: true,
      content: {
        path: realPath,
        size: info.size,
        mime: info.mime,
        encoding,
        content,
        truncated,
        lines: content.length === 0 ? 0 : content.split("\n").length,
      },
    };
  } finally {
    await handle.close();
  }
}

export interface DirectoryEntry {
  name: string;
  kind: "file" | "directory" | "other";
  size: number;
  // Matches the repository's .gitignore rules. Shown dimmed and last, never
  // hidden: the phone must not lie about what is on disk.
  ignored: boolean;
  preview: FileStat["preview"];
}

export interface DirectoryListing {
  path: string;
  entries: DirectoryEntry[];
  truncated: boolean;
}

// Folders first, then files, each alphabetical; ignored entries after the
// rest. `.git` itself is listed (it is on disk) but nothing under it opens.
export async function listDirectory(realPath: string): Promise<DirectoryListing> {
  const dirents = await fs.readdir(realPath, { withFileTypes: true });
  const ignored = await gitIgnored(
    realPath,
    dirents.map((entry) => entry.name),
  );
  const entries: DirectoryEntry[] = [];
  for (const dirent of dirents.slice(0, MAX_LISTING_ENTRIES)) {
    const full = path.join(realPath, dirent.name);
    let info: FileStat | undefined;
    try {
      info = await statFile(full);
    } catch {
      // A broken symlink or a race with a delete: list the name, say nothing more.
    }
    entries.push({
      name: dirent.name,
      kind: dirent.isDirectory() ? "directory" : dirent.isFile() ? "file" : (info?.kind ?? "other"),
      size: info?.size ?? 0,
      ignored: ignored.has(dirent.name),
      preview: info?.preview ?? "binary",
    });
  }
  entries.sort((a, b) => {
    if (a.ignored !== b.ignored) return a.ignored ? 1 : -1;
    const aDir = a.kind === "directory";
    const bDir = b.kind === "directory";
    if (aDir !== bDir) return aDir ? -1 : 1;
    return a.name.localeCompare(b.name, undefined, { sensitivity: "base" });
  });
  return { path: realPath, entries, truncated: dirents.length > MAX_LISTING_ENTRIES };
}

// Which of these names .gitignore covers, per git itself. Not a repository,
// or git missing: nothing is ignored. Never throws — a listing is not worth
// failing over an ignore check.
function gitIgnored(directory: string, names: string[]): Promise<Set<string>> {
  if (names.length === 0) return Promise.resolve(new Set());
  return new Promise((resolve) => {
    const chunks: Buffer[] = [];
    let settled = false;
    const finish = (stdout: string) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(new Set(stdout.split("\0").filter((name) => name.length > 0)));
    };
    const child = spawn("git", ["-C", directory, "check-ignore", "-z", "--stdin"], { stdio: ["pipe", "pipe", "ignore"] });
    const timer = setTimeout(() => {
      child.kill();
      finish("");
    }, GIT_TIMEOUT_MS);
    child.stdout.on("data", (chunk: Buffer) => chunks.push(chunk));
    child.on("error", () => finish(""));
    // Exit 1 means "nothing ignored" and 128 "not a repository"; whatever
    // git printed before exiting is the answer either way.
    child.on("close", () => finish(Buffer.concat(chunks).toString("utf8")));
    child.stdin.on("error", () => undefined);
    child.stdin.end(`${names.join("\0")}\0`);
  });
}

// A first-8-KB NUL sniff, the same heuristic git uses to call a file binary.
async function isText(realPath: string, size: number): Promise<boolean> {
  if (size === 0) return true;
  const handle = await fs.open(realPath, "r");
  try {
    const length = Math.min(size, BINARY_SNIFF_BYTES);
    const buffer = Buffer.alloc(length);
    const { bytesRead } = await handle.read(buffer, 0, length, 0);
    const bytes = buffer.subarray(0, bytesRead);
    // UTF-16 text legitimately contains NULs; its BOM says so.
    if (hasUtf16Bom(bytes)) return true;
    return !bytes.includes(0);
  } finally {
    await handle.close();
  }
}

function hasUtf16Bom(bytes: Buffer): boolean {
  return bytes.length >= 2 && ((bytes[0] === 0xff && bytes[1] === 0xfe) || (bytes[0] === 0xfe && bytes[1] === 0xff));
}

function decodeText(bytes: Buffer): { encoding: FileContent["encoding"]; text: string } {
  if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) {
    return { encoding: "utf-16le", text: bytes.subarray(2).toString("utf16le") };
  }
  if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) {
    return { encoding: "utf-16be", text: swapPairs(bytes.subarray(2)).toString("utf16le") };
  }
  const utf8 = bytes.subarray(bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf ? 3 : 0);
  try {
    return { encoding: "utf-8", text: new TextDecoder("utf-8", { fatal: true }).decode(utf8) };
  } catch {
    return { encoding: "latin1", text: utf8.toString("latin1") };
  }
}

function swapPairs(bytes: Buffer): Buffer {
  const swapped = Buffer.from(bytes);
  for (let index = 0; index + 1 < swapped.length; index += 2) {
    const first = swapped[index] as number;
    swapped[index] = swapped[index + 1] as number;
    swapped[index + 1] = first;
  }
  return swapped;
}

const MIME_BY_EXTENSION: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".heic": "image/heic",
  ".svg": "image/svg+xml",
  ".pdf": "application/pdf",
  ".md": "text/markdown",
  ".markdown": "text/markdown",
  ".json": "application/json",
  ".txt": "text/plain",
  ".html": "text/html",
  ".css": "text/css",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".ts": "text/typescript",
  ".tsx": "text/typescript",
  ".swift": "text/x-swift",
  ".py": "text/x-python",
  ".rb": "text/x-ruby",
  ".go": "text/x-go",
  ".rs": "text/x-rust",
  ".sh": "text/x-shellscript",
  ".yml": "text/yaml",
  ".yaml": "text/yaml",
  ".toml": "text/toml",
};

export function mimeFor(filePath: string): string {
  return MIME_BY_EXTENSION[path.extname(filePath).toLowerCase()] ?? "application/octet-stream";
}
