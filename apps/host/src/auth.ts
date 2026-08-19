import { timingSafeEqual } from "node:crypto";
import type { IncomingMessage } from "node:http";

function constantTimeEqual(left: string, right: string): boolean {
  const a = Buffer.from(left);
  const b = Buffer.from(right);
  return a.length === b.length && timingSafeEqual(a, b);
}

export function bearerToken(request: IncomingMessage): string | undefined {
  const authorization = request.headers.authorization;
  if (!authorization?.startsWith("Bearer ")) return undefined;
  return authorization.slice(7).trim();
}

export function isAuthorized(token: string | undefined, expected: string): boolean {
  return typeof token === "string" && constantTimeEqual(token, expected);
}
