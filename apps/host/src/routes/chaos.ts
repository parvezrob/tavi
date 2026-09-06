import type { ChaosCloseCode, ChaosFaultKind, ChaosFaultRequest, ChaosSocketKind } from "../chaos.js";
import { bodyRecord, readJsonBody, type Route, sendJson } from "../http.js";

// The chaos control surface (#111). It exists only on a host started with
// `TAVI_CHAOS=on`; without one the route declines and the ordinary 404 stands,
// so nothing about a real host changes.

const KINDS: ChaosFaultKind[] = ["terminate", "blackhole", "closeMidOutput", "hostPause"];
const SOCKETS: ChaosSocketKind[] = ["events", "terminal"];
const CODES: ChaosCloseCode[] = [1011, 1001];
const MIN_WINDOW_MS = 1_000;
const MAX_WINDOW_MS = 120_000;

export const chaosRoutes: Route = async (url, request, response, context) => {
  const { chaos } = context;
  if (!chaos) return false;

  if (url.pathname === "/api/chaos/fault" && request.method === "POST") {
    const parsed = parseFault(bodyRecord(await readJsonBody(request)));
    if (!parsed.ok) {
      sendJson(response, 400, { error: parsed.error });
      return true;
    }
    const outcome = chaos.fault(parsed.request);
    if (!outcome.ok) {
      sendJson(response, outcome.status, { error: outcome.error });
      return true;
    }
    sendJson(response, 201, { id: outcome.event.id, at: outcome.event.at });
    return true;
  }

  if (url.pathname === "/api/chaos/events" && request.method === "GET") {
    sendJson(response, 200, { events: chaos.events() });
    return true;
  }

  if (url.pathname === "/api/chaos/attachments" && request.method === "GET") {
    sendJson(response, 200, { attachments: chaos.attachments() });
    return true;
  }

  return false;
};

type ParsedFault = { ok: true; request: ChaosFaultRequest } | { ok: false; error: string };

function parseFault(body: Record<string, unknown>): ParsedFault {
  const kind = KINDS.find((candidate) => candidate === body.kind);
  if (!kind) return { ok: false, error: `\`kind\` must be one of ${KINDS.join(", ")}.` };

  // `hostPause` withholds every answer the host would give, so it names no
  // socket; the other three each act on one.
  const named = SOCKETS.find((candidate) => candidate === body.socket);
  const socket = named ?? (kind === "hostPause" ? "events" : undefined);
  if (!socket) return { ok: false, error: "`socket` must be `events` or `terminal`." };

  const request: ChaosFaultRequest = { kind, socket };
  if (kind !== "hostPause" && socket === "terminal") {
    if (typeof body.paneId !== "string" || !/^[A-Za-z0-9_.:-]{1,128}$/.test(body.paneId)) {
      return { ok: false, error: "`paneId` is required for a terminal fault." };
    }
    request.paneId = body.paneId;
  }

  if (kind === "blackhole" || kind === "hostPause") {
    const ms = body.ms;
    if (typeof ms !== "number" || !Number.isFinite(ms) || ms < MIN_WINDOW_MS || ms > MAX_WINDOW_MS) {
      return { ok: false, error: `\`ms\` must be a number between ${MIN_WINDOW_MS} and ${MAX_WINDOW_MS}.` };
    }
    request.ms = ms;
  }

  if (kind === "closeMidOutput") {
    const code = CODES.find((candidate) => candidate === body.code);
    if (!code) return { ok: false, error: "`code` must be 1011 or 1001." };
    request.code = code;
  }

  if (body.thenSlowReadyMs !== undefined) {
    // Only a terminal fault can arm one: `slowReady` delays the next attach on
    // a pane, and an events socket has no attach to delay.
    if (request.paneId === undefined || (kind !== "terminate" && kind !== "closeMidOutput")) {
      return { ok: false, error: "`thenSlowReadyMs` needs a terminal `terminate` or `closeMidOutput`." };
    }
    const ms = body.thenSlowReadyMs;
    if (typeof ms !== "number" || !Number.isFinite(ms) || ms < 0 || ms > MAX_WINDOW_MS) {
      return { ok: false, error: `\`thenSlowReadyMs\` must be a number between 0 and ${MAX_WINDOW_MS}.` };
    }
    request.thenSlowReadyMs = ms;
  }

  return { ok: true, request };
}
