import assert from "node:assert/strict";
import test from "node:test";
import { InputError, safeSessionId } from "./validation.js";

test("rejects unsafe session ids", () => {
  assert.equal(safeSessionId("mocha-api-abc123"), "mocha-api-abc123");
  assert.throws(() => safeSessionId("../../other"), InputError);
});
