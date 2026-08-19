import assert from "node:assert/strict";
import type { IncomingMessage } from "node:http";
import test from "node:test";
import { bearerToken, isAuthorized } from "./auth.js";

function requestWithHeaders(headers: IncomingMessage["headers"]): IncomingMessage {
  return { headers } as IncomingMessage;
}

test("extracts an HTTP bearer token", () => {
  const request = requestWithHeaders({ authorization: "Bearer host-secret" });
  assert.equal(bearerToken(request), "host-secret");
});

test("rejects absent and incorrect credentials", () => {
  assert.equal(isAuthorized(undefined, "expected"), false);
  assert.equal(isAuthorized("unexpected", "expected"), false);
  assert.equal(isAuthorized("expected", "expected"), true);
});
