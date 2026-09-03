import { arch, platform } from "node:os";
import { VERSION } from "../config.js";
import { type Route, sendJson } from "../http.js";
import { connectionPath } from "../tailscale.js";
import type { HostInfo } from "../types.js";

export const hostRoutes: Route = async (url, request, response, context) => {
  const { config, devices, update, tailscale } = context;

  if (url.pathname === "/api/host" && request.method === "GET") {
    const host: HostInfo = {
      name: config.machineName,
      platform: platform(),
      arch: arch(),
      version: VERSION,
    };
    // The caller's path per this computer's Tailscale (#86): the phone
    // says "relay" in words instead of blaming the computer for a slow
    // link. Never slower than the cached status; "unknown" on any doubt.
    const connection = await connectionPath(request, ...(tailscale ? [tailscale] : []));
    sendJson(response, 200, { ...host, fingerprint: devices.identity().fingerprint, connection });
    return true;
  }

  if (url.pathname === "/api/update" && request.method === "POST") {
    const outcome = update
      ? await update()
      : { status: "skipped", reason: "this host does not manage its own updates" };
    sendJson(response, 200, outcome);
    return true;
  }
  return false;
};
