import { createReadStream } from "node:fs";
import path from "node:path";
import { diffFile, listChanges } from "../changes.js";
import { listDirectory, MAX_RAW_BYTES, readTextContent, resolveWithinRoots, statFile } from "../files.js";
import { type Route, sendJson, sendPathFailure } from "../http.js";
import { readUploadBody, saveUpload } from "../uploads.js";

export const fileRoutes: Route = async (url, request, response, context) => {
  const { config } = context;

  // Read-only files (#25 changes, #61 mentioned, #57 browse). Every route
  // takes the agent's `cwd` and a `path` (absolute, or relative to cwd);
  // `resolveWithinRoots` follows symlinks first and checks the configured
  // roots second, so nothing outside them is reachable by any spelling.
  // Nothing here writes.
  if (url.pathname === "/api/changes" && request.method === "GET") {
    const cwd = await resolveWithinRoots(url.searchParams.get("cwd") ?? "", "/", config.roots);
    if (!cwd.ok) return sendPathFailure(response, cwd);
    const result = await listChanges(cwd.path);
    if (!result.ok) {
      sendJson(response, result.status, {
        error: result.error,
        ...(result.notRepository ? { notRepository: true } : {}),
      });
      return true;
    }
    sendJson(response, 200, {
      repository: result.repository,
      branch: result.branch ?? null,
      files: result.files,
      truncated: result.truncated,
    });
    return true;
  }

  if (url.pathname === "/api/changes/file" && request.method === "GET") {
    const cwd = await resolveWithinRoots(url.searchParams.get("cwd") ?? "", "/", config.roots);
    if (!cwd.ok) return sendPathFailure(response, cwd);
    const result = await diffFile(cwd.path, url.searchParams.get("path") ?? "");
    if (!result.ok) {
      sendJson(response, result.status, { error: result.error });
      return true;
    }
    sendJson(response, 200, result.diff);
    return true;
  }

  // An image attached from the composer (#88): raw body, image types
  // only, into the agent's own folder under .tavi/uploads/. The answer is
  // the path the phone puts into the message.
  if (url.pathname === "/api/files/upload" && request.method === "POST") {
    const cwdParam = url.searchParams.get("cwd") ?? "";
    const body = await readUploadBody(request);
    if (!body) {
      sendJson(response, 413, { error: "Images are limited to 10 MB." });
      return true;
    }
    const saved = await saveUpload({
      cwd: cwdParam,
      roots: config.roots,
      contentType: request.headers["content-type"],
      body,
    });
    if (!saved.ok) return sendPathFailure(response, saved);
    sendJson(response, 201, { path: saved.path, bytes: saved.bytes });
    return true;
  }

  const filesRoute =
    url.pathname === "/api/files" ||
    url.pathname === "/api/files/stat" ||
    url.pathname === "/api/files/content" ||
    url.pathname === "/api/files/raw";
  if (filesRoute && request.method === "GET") {
    const cwdParam = url.searchParams.get("cwd") ?? "";
    const target = url.searchParams.get("path") ?? ".";
    const resolved = await resolveWithinRoots(target, path.isAbsolute(cwdParam) ? cwdParam : "/", config.roots);
    if (!resolved.ok) return sendPathFailure(response, resolved);
    if (url.pathname === "/api/files/stat") {
      sendJson(response, 200, { ...(await statFile(resolved.path)), relativePath: resolved.relativePath });
      return true;
    }
    if (url.pathname === "/api/files") {
      const info = await statFile(resolved.path);
      if (info.kind !== "directory") {
        sendJson(response, 400, { error: "That is a file, not a folder." });
        return true;
      }
      sendJson(response, 200, { ...(await listDirectory(resolved.path)), relativePath: resolved.relativePath });
      return true;
    }
    if (url.pathname === "/api/files/content") {
      const result = await readTextContent(resolved.path);
      if (!result.ok) {
        sendJson(response, result.status, {
          error: result.error,
          preview: result.preview,
          size: result.size,
          mime: result.mime,
        });
        return true;
      }
      sendJson(response, 200, { ...result.content, relativePath: resolved.relativePath });
      return true;
    }
    // /api/files/raw: images and PDFs, streamed whole, size-capped. Text and
    // everything else go through /content, which knows how to refuse.
    const info = await statFile(resolved.path);
    if (info.preview !== "image" && info.preview !== "pdf") {
      sendJson(response, 415, {
        error: "Only images and PDFs are served raw.",
        preview: info.preview,
        size: info.size,
        mime: info.mime,
      });
      return true;
    }
    if (info.size > MAX_RAW_BYTES) {
      sendJson(response, 413, {
        error: "This file is too large to preview on the phone.",
        preview: info.preview,
        size: info.size,
        mime: info.mime,
      });
      return true;
    }
    response.writeHead(200, {
      "Content-Type": info.mime,
      "Content-Length": String(info.size),
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    });
    createReadStream(resolved.path)
      .on("error", () => response.destroy())
      .pipe(response);
    return true;
  }
  return false;
};
