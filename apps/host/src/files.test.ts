import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
  listDirectory,
  looksLikeASecret,
  readTextContent,
  resolveWithinRoots,
  statFile,
} from "./files.js";

function scratch(): { root: string; outside: string } {
  const base = mkdtempSync(path.join(tmpdir(), "tavi-files-"));
  const root = path.join(base, "Projects");
  const outside = path.join(base, "elsewhere");
  mkdirSync(path.join(root, "app", "src"), { recursive: true });
  mkdirSync(outside, { recursive: true });
  writeFileSync(path.join(root, "app", "README.md"), "# App\n\nhello\n");
  writeFileSync(path.join(root, "app", "src", "main.ts"), "export const x = 1;\n");
  writeFileSync(path.join(outside, "settings.json"), "{\"token\":\"nope\"}\n");
  return { root, outside };
}

test("resolves a relative path against the agent's cwd and stays inside the roots", async () => {
  const { root } = scratch();
  const cwd = path.join(root, "app");
  const resolved = await resolveWithinRoots("src/main.ts", cwd, [root]);
  assert.ok(resolved.ok);
  assert.equal(resolved.path, realpathSync(path.join(cwd, "src", "main.ts")));
  assert.equal(resolved.relativePath, "src/main.ts");
});

test("a path outside the roots is refused by name, whether or not it exists", async () => {
  const { root, outside } = scratch();
  const cwd = path.join(root, "app");
  const real = await resolveWithinRoots(path.join(outside, "settings.json"), cwd, [root]);
  assert.deepEqual(real, { ok: false, status: 403, error: "That file is outside your project folders.", outsideRoots: true });
  const missing = await resolveWithinRoots(path.join(outside, "nope.txt"), cwd, [root]);
  assert.equal(missing.ok, false);
  assert.equal((missing as { status: number }).status, 403);
  const climbed = await resolveWithinRoots("../../elsewhere/settings.json", cwd, [root]);
  assert.equal((climbed as { status: number }).status, 403);
});

test("a symlink that points out of the roots is refused after realpath (#57)", async () => {
  const { root, outside } = scratch();
  const cwd = path.join(root, "app");
  symlinkSync(path.join(outside, "settings.json"), path.join(cwd, "innocent.json"));
  const resolved = await resolveWithinRoots("innocent.json", cwd, [root]);
  assert.equal(resolved.ok, false);
  assert.equal((resolved as { status: number }).status, 403);
  // A symlinked directory too.
  symlinkSync(outside, path.join(cwd, "vendor"));
  const viaDirectory = await resolveWithinRoots("vendor/settings.json", cwd, [root]);
  assert.equal((viaDirectory as { status: number }).status, 403);
});

test("a symlinked root still contains its real files", async () => {
  const { root } = scratch();
  const base = path.dirname(root);
  const link = path.join(base, "ProjectsLink");
  symlinkSync(root, link);
  const resolved = await resolveWithinRoots("app/README.md", link, [link]);
  assert.ok(resolved.ok);
});

test("a missing file inside the roots is a plain 404; git internals are refused", async () => {
  const { root } = scratch();
  const cwd = path.join(root, "app");
  const missing = await resolveWithinRoots("src/gone.ts", cwd, [root]);
  assert.deepEqual(missing, { ok: false, status: 404, error: "No such file." });
  mkdirSync(path.join(cwd, ".git", "objects"), { recursive: true });
  writeFileSync(path.join(cwd, ".git", "HEAD"), "ref: refs/heads/main\n");
  const head = await resolveWithinRoots(".git/HEAD", cwd, [root]);
  assert.equal((head as { status: number }).status, 403);
});

test("text content is served with its encoding; binary and secrets are refused with their kind", async () => {
  const { root } = scratch();
  const cwd = path.join(root, "app");
  const text = await readTextContent(path.join(cwd, "src", "main.ts"));
  assert.ok(text.ok);
  assert.equal(text.content.content, "export const x = 1;\n");
  assert.equal(text.content.encoding, "utf-8");
  assert.equal(text.content.mime, "text/typescript");
  assert.equal(text.content.lines, 2);

  writeFileSync(path.join(cwd, "blob.bin"), Buffer.from([0x89, 0x50, 0x00, 0x47, 0x0d, 0x0a]));
  const binary = await readTextContent(path.join(cwd, "blob.bin"));
  assert.equal(binary.ok, false);
  assert.equal((binary as { status: number }).status, 415);
  assert.equal((binary as { preview: string }).preview, "binary");

  writeFileSync(path.join(cwd, ".env"), "SECRET=1\n");
  const secret = await readTextContent(path.join(cwd, ".env"));
  assert.equal(secret.ok, false);
  assert.equal((secret as { status: number }).status, 403);
  assert.equal((secret as { preview: string }).preview, "secret");

  writeFileSync(path.join(cwd, "utf16.txt"), Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from("hi\n", "utf16le")]));
  const utf16 = await readTextContent(path.join(cwd, "utf16.txt"));
  assert.ok(utf16.ok);
  assert.equal(utf16.content.encoding, "utf-16le");
  assert.equal(utf16.content.content, "hi\n");
});

test("a file over the cap is cut at a line boundary and marked truncated", async () => {
  const { root } = scratch();
  const cwd = path.join(root, "app");
  const line = "0123456789\n";
  writeFileSync(path.join(cwd, "big.log"), line.repeat(100));
  const result = await readTextContent(path.join(cwd, "big.log"), 255);
  assert.ok(result.ok);
  assert.ok(result.content.truncated);
  assert.equal(result.content.size, 1100);
  assert.ok(result.content.content.endsWith("9"));
  assert.equal(result.content.content.length % line.length, line.length - 1);
});

test("stat classifies previews; images and PDFs are their own kinds", async () => {
  const { root } = scratch();
  const cwd = path.join(root, "app");
  writeFileSync(path.join(cwd, "shot.png"), Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x00]));
  writeFileSync(path.join(cwd, "doc.pdf"), "%PDF-1.4\n\0");
  assert.equal((await statFile(path.join(cwd, "shot.png"))).preview, "image");
  assert.equal((await statFile(path.join(cwd, "doc.pdf"))).preview, "pdf");
  assert.equal((await statFile(path.join(cwd, "README.md"))).preview, "text");
  assert.equal((await statFile(path.join(cwd, "src"))).preview, "directory");
});

test("listing puts folders first, files alphabetical, and gitignored entries dimmed last — never hidden", async () => {
  const { root } = scratch();
  const cwd = path.join(root, "app");
  execFileSync("git", ["-C", cwd, "init", "-q"]);
  writeFileSync(path.join(cwd, ".gitignore"), "node_modules/\n*.log\n");
  mkdirSync(path.join(cwd, "node_modules"));
  writeFileSync(path.join(cwd, "debug.log"), "x\n");
  writeFileSync(path.join(cwd, "b.txt"), "b\n");
  writeFileSync(path.join(cwd, "a.txt"), "a\n");
  const listing = await listDirectory(cwd);
  const names = listing.entries.map((entry) => `${entry.name}${entry.ignored ? "*" : ""}`);
  assert.deepEqual(names, [".git", "src", ".gitignore", "a.txt", "b.txt", "README.md", "node_modules*", "debug.log*"]);
  assert.equal(listing.truncated, false);
});

test("listing outside a repository dims nothing", async () => {
  const { root } = scratch();
  const listing = await listDirectory(path.join(root, "app"));
  assert.ok(listing.entries.every((entry) => !entry.ignored));
});

test("the secrets rule is by name", () => {
  for (const name of [".env", ".env.local", "id_rsa", "id_ed25519.pub", "server.pem", "aws-credentials.json", "client_secret.json", ".npmrc"]) {
    assert.ok(looksLikeASecret(`/x/${name}`), name);
  }
  for (const name of ["README.md", "environment.ts", "keys.md", "main.swift"]) {
    assert.ok(!looksLikeASecret(`/x/${name}`), name);
  }
});
