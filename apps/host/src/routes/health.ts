import { VERSION } from "../config.js";
import { type Route, sendJson } from "../http.js";

export const healthRoutes: Route = async (url, request, response, _context) => {
  if (url.pathname === "/api/health" && request.method === "GET") {
    sendJson(response, 200, { ok: true, version: VERSION });
    return true;
  }
  return false;
};
