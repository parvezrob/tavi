export class InputError extends Error {}

// Pane ids travel in URL paths; herdr ids look like `wB:p12`.
export function safeSessionId(value: string): string {
  const decoded = decodeURIComponent(value);
  if (!/^[A-Za-z0-9_.:-]{1,128}$/.test(decoded)) throw new InputError("Invalid session id.");
  return decoded;
}
