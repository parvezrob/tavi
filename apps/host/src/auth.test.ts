import assert from "node:assert/strict";
import type { IncomingMessage } from "node:http";
import test from "node:test";
import { bearerToken, isAuthorized, websocketToken } from "./auth.js";

function requestWithHeaders(headers: IncomingMessage["headers"]): IncomingMessage {
  return { headers } as IncomingMessage;
}

test("extracts an HTTP bearer token", () => {
  const request = requestWithHeaders({ authorization: "Bearer host-secret" });
  assert.equal(bearerToken(request), "host-secret");
});

test("extracts a UTF-8 token from the terminal WebSocket protocols", () => {
  const token = "host-secret-🔐";
  const encoded = Buffer.from(token, "utf8").toString("base64url");
  const request = requestWithHeaders({
    "sec-websocket-protocol": `deck.v1, deck.token.${encoded}`,
  });

  assert.equal(websocketToken(request), token);
});

test("rejects absent and incorrect credentials", () => {
  assert.equal(isAuthorized(undefined, "expected"), false);
  assert.equal(isAuthorized("unexpected", "expected"), false);
  assert.equal(isAuthorized("expected", "expected"), true);
});
