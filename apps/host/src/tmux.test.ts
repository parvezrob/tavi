import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test, { type TestContext } from "node:test";
import { TmuxService } from "./tmux.js";

const SEPARATOR = "\u001f";

test("recognizes both Mocha and legacy managed sessions", async () => {
  const service = new TmuxService({
    bin: "tmux",
    shell: "/bin/zsh",
    roots: [],
    execute: async () =>
      [
        sessionLine("mocha-api-work-a1b2c3", "codex"),
        sessionLine("deck-old-work-d4e5f6", "claude"),
        sessionLine("personal", "/bin/zsh"),
      ].join("\n"),
  });

  const sessions = await service.listSessions();

  assert.deepEqual(
    sessions.map(({ id, name, managed }) => ({ id, name, managed })),
    [
      { id: "mocha-api-work-a1b2c3", name: "api work", managed: true },
      { id: "deck-old-work-d4e5f6", name: "old work", managed: true },
      { id: "personal", name: "personal", managed: false },
    ],
  );
});

test("creates only Mocha-prefixed sessions", async (context) => {
  const workingDirectory = temporaryDirectory(context);
  let createdId = "";
  const calls: string[][] = [];
  const service = new TmuxService({
    bin: "tmux",
    shell: "/bin/zsh",
    roots: [],
    execute: async (args) => {
      calls.push(args);
      if (args[0] === "new-session") {
        createdId = args[args.indexOf("-s") + 1] || "";
        return "";
      }
      return sessionLine(createdId, "codex");
    },
  });

  const session = await service.createSession({
    name: "API Work",
    cwd: workingDirectory,
    agent: "codex",
  });

  assert.match(session.id, /^mocha-api-work-[a-f0-9]{6}$/);
  assert.equal(calls[0]?.includes("codex"), true);
});

function sessionLine(id: string, command: string): string {
  return [id, "100", "100", "0", "1", "/project", command].join(SEPARATOR);
}

function temporaryDirectory(context: TestContext): string {
  const directory = mkdtempSync(path.join(tmpdir(), "mocha-tmux-test-"));
  context.after(() => rmSync(directory, { recursive: true, force: true }));
  return directory;
}
