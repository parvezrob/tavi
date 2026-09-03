import { bearerToken, isAuthorized } from "../auth.js";
import { type Route, sendJson } from "../http.js";
import { safeSessionId } from "../validation.js";

export const deviceRoutes: Route = async (url, request, response, context) => {
  const { config, devices } = context;

  // Paired-device management (#46). Listing and revoking others is the host
  // owner's act; a phone may only unpair itself.
  if (url.pathname === "/api/devices" && request.method === "GET") {
    if (!isAuthorized(bearerToken(request), config.token)) {
      sendJson(response, 403, { error: "Only the host itself can list paired devices." });
      return true;
    }
    sendJson(response, 200, { devices: devices.list() });
    return true;
  }
  if (url.pathname === "/api/devices/me" && request.method === "DELETE") {
    const me = devices.authorize(bearerToken(request) ?? "");
    if (!me) {
      sendJson(response, 400, { error: "Only a paired phone can unpair itself." });
      return true;
    }
    devices.revoke(me.id);
    response.writeHead(204).end();
    return true;
  }
  const deviceMatch = url.pathname.match(/^\/api\/devices\/([^/]+)$/);
  if (deviceMatch && request.method === "DELETE") {
    if (!isAuthorized(bearerToken(request), config.token)) {
      sendJson(response, 403, { error: "Only the host itself can revoke a device." });
      return true;
    }
    if (!devices.revoke(safeSessionId(deviceMatch[1] || ""))) {
      sendJson(response, 404, { error: "No paired device with that id." });
      return true;
    }
    response.writeHead(204).end();
    return true;
  }
  return false;
};
