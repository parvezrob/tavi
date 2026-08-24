import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import test, { type TestContext } from "node:test";
import { HerdrService } from "./herdr.js";

test("maps live herdr agents with provenance", async (context) => {
  const socketPath = temporarySocketPath(context);
  await startFakeHerdr(context, socketPath, {
    protocol: 17,
    agents: [
      {
        agent: "claude",
        agent_status: "blocked",
        cwd: "/Users/dev/project",
        focused: true,
        pane_id: "wB:p1",
        revision: 3,
        tab_id: "wB:t1",
        terminal_title: "✳ Claude Code",
        terminal_title_stripped: "Claude Code",
        workspace_id: "wB",
      },
      {
        agent: "codex",
        agent_status: "definitely-new-status",
        pane_id: "wB:p2",
        tab_id: "wB:t2",
        workspace_id: "wB",
      },
    ],
  });

  const result = await new HerdrService({ socketPath }).listAgents();

  assert.equal(result.available, true);
  assert.equal(result.protocol, 17);
  assert.deepEqual(
    result.agents.map(({ id, agent, status, title, focused, authority }) => ({
      id,
      agent,
      status,
      title,
      focused,
      authority,
    })),
    [
      {
        id: "wB:p1",
        agent: "claude",
        status: "blocked",
        title: "Claude Code",
        focused: true,
        authority: "herdr",
      },
      {
        id: "wB:p2",
        agent: "codex",
        status: "unknown",
        title: "",
        focused: false,
        authority: "herdr",
      },
    ],
  );
});

test("reports unavailable when the herdr server is not running", async (context) => {
  const socketPath = temporarySocketPath(context);

  const result = await new HerdrService({ socketPath }).listAgents();

  assert.equal(result.available, false);
  assert.equal(result.agents.length, 0);
  assert.equal(result.reason, "The Herdr server is not running.");
});

test("fails closed on an unsupported herdr protocol", async (context) => {
  const socketPath = temporarySocketPath(context);
  await startFakeHerdr(context, socketPath, { protocol: 16, agents: [] });

  const result = await new HerdrService({ socketPath }).listAgents();

  assert.equal(result.available, false);
  assert.equal(result.agents.length, 0);
  assert.match(result.reason ?? "", /protocol 16 is not supported/);
});

test("reports unavailable when herdr stops responding", async (context) => {
  const socketPath = temporarySocketPath(context);
  const server = createServer(() => {
    // Accept the connection and never answer.
  });
  await listen(context, server, socketPath);

  const result = await new HerdrService({
    socketPath,
    requestTimeoutMilliseconds: 100,
  }).listAgents();

  assert.equal(result.available, false);
  assert.equal(result.reason, "Herdr did not respond in time.");
});

function temporarySocketPath(context: TestContext): string {
  const directory = mkdtempSync(path.join(tmpdir(), "mocha-herdr-test-"));
  context.after(() => rmSync(directory, { recursive: true, force: true }));
  return path.join(directory, "herdr.sock");
}

async function startFakeHerdr(
  context: TestContext,
  socketPath: string,
  behavior: { protocol: number; agents: unknown[] },
): Promise<void> {
  const server = createServer((socket) => {
    let buffered = "";
    socket.on("data", (chunk) => {
      buffered += chunk.toString("utf8");
      const lineEnd = buffered.indexOf("\n");
      if (lineEnd === -1) return;
      const request = JSON.parse(buffered.slice(0, lineEnd)) as { id: string; method: string };
      buffered = buffered.slice(lineEnd + 1);
      const result =
        request.method === "ping"
          ? { type: "pong", version: "0.7.5", protocol: behavior.protocol }
          : { type: "agent_list", agents: behavior.agents };
      socket.write(`${JSON.stringify({ id: request.id, result })}\n`);
    });
  });
  await listen(context, server, socketPath);
}

function listen(context: TestContext, server: Server, socketPath: string): Promise<void> {
  context.after(() => {
    server.close();
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
}
