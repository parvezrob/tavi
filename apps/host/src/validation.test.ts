import assert from "node:assert/strict";
import test from "node:test";
import { InputError, parseCreateSession, safeSessionId } from "./validation.js";

test("parses a valid session request", () => {
  assert.deepEqual(parseCreateSession({ name: "API work", cwd: "/tmp", agent: "codex" }), {
    name: "API work",
    cwd: "/tmp",
    agent: "codex",
  });
});

test("requires a command for custom sessions", () => {
  assert.throws(() => parseCreateSession({ name: "Custom", cwd: "/tmp", agent: "custom" }), InputError);
});

test("rejects unsafe session ids", () => {
  assert.equal(safeSessionId("mocha-api-abc123"), "mocha-api-abc123");
  assert.throws(() => safeSessionId("../../other"), InputError);
});
