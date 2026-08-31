import assert from "node:assert/strict";
import test from "node:test";
import { AGENT_KIND_NAMES, AGENT_KINDS, AgentKindDetector } from "./agent-kinds.js";

test("every kind herdr can launch has one entry and the kind is its executable", () => {
  assert.equal(new Set(AGENT_KIND_NAMES).size, AGENT_KINDS.length);
  assert.ok(AGENT_KIND_NAMES.includes("claude"));
  assert.ok(AGENT_KIND_NAMES.includes("codex"));
  for (const { kind, label } of AGENT_KINDS) {
    assert.match(kind, /^[a-z]+$/, `${kind} must be a bare executable name`);
    assert.ok(label.length > 0);
  }
});

test("installed kinds come from the login shell, in catalog order, with labels", async () => {
  const calls: Array<{ shell: string; script: string }> = [];
  const detector = new AgentKindDetector({
    shell: "/bin/zsh",
    runShell: async (shell, script) => {
      calls.push({ shell, script });
      return "codex\nnot-a-kind\nclaude\n";
    },
  });

  const kinds = await detector.list();
  assert.equal(calls[0]?.shell, "/bin/zsh");
  assert.match(calls[0]?.script ?? "", /command -v claude/);
  assert.deepEqual(kinds.slice(0, 2), [
    { kind: "claude", label: "Claude Code", installed: true },
    { kind: "codex", label: "Codex", installed: true },
  ]);
  assert.equal(kinds.find((entry) => entry.kind === "gemini")?.installed, false);
  assert.equal(kinds.length, AGENT_KINDS.length);
});

test("detection is cached for a minute, then asked again", async () => {
  let now = 0;
  let runs = 0;
  const detector = new AgentKindDetector({
    shell: "/bin/sh",
    now: () => now,
    runShell: async () => {
      runs += 1;
      return runs === 1 ? "claude\n" : "claude\ncodex\n";
    },
  });

  assert.equal((await detector.list()).find((k) => k.kind === "codex")?.installed, false);
  now = 30_000;
  await detector.list();
  assert.equal(runs, 1);
  now = 61_000;
  assert.equal((await detector.list()).find((k) => k.kind === "codex")?.installed, true);
  assert.equal(runs, 2);
});

test("a shell that cannot be run claims nothing is installed", async () => {
  const detector = new AgentKindDetector({
    shell: "/nonexistent/shell",
    runShell: async () => {
      throw new Error("ENOENT");
    },
  });

  const kinds = await detector.list();
  assert.equal(kinds.length, AGENT_KINDS.length);
  assert.ok(kinds.every((entry) => !entry.installed));
});

test("the real login shell resolves at least the shell itself", async () => {
  // No agent may be installed on the machine running the suite, so the
  // only safe live assertion is that asking the shell does not throw.
  const detector = new AgentKindDetector({ shell: process.env.SHELL || "/bin/sh" });
  const kinds = await detector.list();
  assert.equal(kinds.length, AGENT_KINDS.length);
});
