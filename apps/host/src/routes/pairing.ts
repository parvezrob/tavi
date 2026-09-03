import { bearerToken, isAuthorized } from "../auth.js";
import { bodyRecord, readJsonBody, type Route, sendJson } from "../http.js";

export const publicPairingRoutes: Route = async (url, request, response, context) => {
  const { config, devices, pairing } = context;

  // The one unauthenticated write: redeeming a pairing secret (#45). The
  // secret is single-use, 128-bit, and dies in five minutes; the phone gets
  // its own credential back and the host's token never leaves the Mac.
  if (url.pathname === "/api/pair" && request.method === "POST") {
    const body = await readJsonBody(request);
    const record = bodyRecord(body);
    const secret = typeof record.secret === "string" ? record.secret : "";
    const deviceName = typeof record.deviceName === "string" ? record.deviceName : "";
    if (!pairing.redeem(secret)) {
      sendJson(response, 401, {
        error: "That pairing code is not valid any more. Run `tavi pair` on the Mac for a fresh one.",
      });
      return true;
    }
    const { device, credential } = devices.add(deviceName);
    sendJson(response, 201, {
      credential,
      device,
      host: { name: config.machineName, fingerprint: devices.identity().fingerprint },
    });
    return true;
  }
  return false;
};

export const pairingRoutes: Route = async (url, request, response, context) => {
  const { config, devices, pairing } = context;

  // Minting a pairing code is the host owner's act: only the host token may,
  // never an already-paired phone.
  if (url.pathname === "/api/pair/begin" && request.method === "POST") {
    if (!isAuthorized(bearerToken(request), config.token)) {
      sendJson(response, 403, { error: "Only the host itself can start pairing." });
      return true;
    }
    try {
      const { secret, expiresAt } = pairing.begin();
      sendJson(response, 201, {
        secret,
        expiresAt,
        host: { name: config.machineName, fingerprint: devices.identity().fingerprint },
      });
    } catch (error) {
      sendJson(response, 429, { error: error instanceof Error ? error.message : "Could not start pairing." });
    }
    return true;
  }
  return false;
};
