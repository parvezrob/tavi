import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import test, { type TestContext } from "node:test";
import { claudeHookCommand, installClaudeHooks } from "./claude-hooks.js";
import type { HostConfig } from "./config.js";

const config = { port: 4820 } as HostConfig;

test("hook command never carries the token or a token expansion", () => {
  const command = claudeHookCommand(config, "/opt/mocha/dist/claude-hook-relay.js");

  assert.equal(command.includes("$("), false, "no shell expansion may produce the token");
  assert.equal(command.toLowerCase().includes("bearer"), false);
  assert.match(command, /claude-hook-relay\.js' 4820/);
  assert.match(command, /\|\| true$/);
});

test("install replaces the legacy curl command and keeps foreign hooks", () => {
  const directory = mkdtempSync(path.join(tmpdir(), "mocha-hooks-test-"));
  const settingsPath = path.join(directory, "settings.json");
  const foreign = { hooks: [{ type: "command", command: "say hi" }] };
  const legacyMocha = {
    hooks: [{ type: "command", command: "curl -s http://127.0.0.1:4820/api/hooks/claude" }],
  };
  writeFileSync(
    settingsPath,
    JSON.stringify({ hooks: { Notification: [foreign, legacyMocha] } }),
    "utf8",
  );

  const { changed } = installClaudeHooks(config, settingsPath);
  rmSync(directory, { recursive: true, force: true });

  assert.equal(changed, true);
});

test("install is idempotent once the relay command is in place", () => {
  const directory = mkdtempSync(path.join(tmpdir(), "mocha-hooks-test-"));
  const settingsPath = path.join(directory, "settings.json");

  installClaudeHooks(config, settingsPath);
  const first = readFileSync(settingsPath, "utf8");
  const { changed } = installClaudeHooks(config, settingsPath);
  const second = readFileSync(settingsPath, "utf8");
  rmSync(directory, { recursive: true, force: true });

  assert.equal(changed, false);
  assert.equal(first, second);
  assert.equal(first.includes("$("), false);
  assert.match(first, /claude-hook-relay\.js/);
});

test("relay posts stdin to the host with the token from the config file", async (context) => {
  const home = mkdtempSync(path.join(tmpdir(), "mocha-relay-home-"));
  context.after(() => rmSync(home, { recursive: true, force: true }));
  mkdirSync(path.join(home, ".mocha"), { recursive: true });
  writeFileSync(
    path.join(home, ".mocha", "config.json"),
    JSON.stringify({ token: "relay-secret" }),
    "utf8",
  );

  const received = await new Promise<{ authorization: string; body: string; stdout: string }>(
    (resolve, reject) => {
      const server = createServer((request, response) => {
        const chunks: Buffer[] = [];
        request.on("data", (chunk) => chunks.push(chunk));
        request.on("end", () => {
          response.writeHead(200).end("{}");
          server.close();
          resolve({
            authorization: String(request.headers.authorization),
            body: Buffer.concat(chunks).toString("utf8"),
            stdout,
          });
        });
      });
      let stdout = "";
      server.listen(0, "127.0.0.1", () => {
        const address = server.address();
        const port = typeof address === "object" && address ? address.port : 0;
        const relay = spawn(
          process.execPath,
          ["--import", "tsx", path.join(import.meta.dirname, "claude-hook-relay.ts"), String(port)],
          { env: { ...process.env, HOME: home } },
        );
        relay.stdout.on("data", (chunk) => {
          stdout += chunk.toString("utf8");
        });
        relay.on("error", reject);
        relay.stdin.end('{"hook_event_name":"PermissionRequest","session_id":"abc"}');
      });
      setTimeout(() => {
        server.close();
        reject(new Error("relay never reached the host"));
      }, 10_000).unref();
    },
  );

  assert.equal(received.authorization, "Bearer relay-secret");
  assert.match(received.body, /PermissionRequest/);
  assert.equal(received.stdout, "", "relay must stay silent on stdout");
});
