import type { IncomingMessage } from "node:http";
import { bearerToken, isAuthorized } from "../auth.js";
import type { HostConfig } from "../config.js";
import { resolveWithinRoots } from "../files.js";
import { bodyRecord, type Route, readJsonBody, sendJson, sendPathFailure } from "../http.js";
import type { DeviceRegistry } from "../pairing.js";
import {
  defaultDiscoveryDeps,
  type DiscoveryDeps,
  listProjectServers,
  stopProjectServer,
  TICKET_COOKIE,
  validPort,
} from "../preview.js";

export const previewRoutes: Route = async (url, request, response, context) => {
  const { config, devices, previews, doorReady, discovery } = context;

  // Private dev-server preview (#58). Tickets are minted here, behind the
  // bearer token; the door (a separate loopback listener Tailscale Serve
  // publishes on `previewDoorPort`) honours them. Only the device that
  // opened a preview can keep it alive or close it. See preview.ts.
  if (url.pathname === "/api/preview/door" && request.method === "GET") {
    sendJson(response, 200, { doorPort: config.previewDoorPort, ready: await doorReady(), cookieName: TICKET_COOKIE });
    return true;
  }
  if (url.pathname === "/api/preview/candidates" && request.method === "GET") {
    const cwd = await resolveWithinRoots(url.searchParams.get("cwd") ?? "", "/", config.roots);
    if (!cwd.ok) return sendPathFailure(response, cwd);
    const found = await listProjectServers(cwd.path, config.roots, withOwnPortsExcluded(discovery, config));
    if (!found.available) {
      sendJson(response, 200, { available: false, reason: found.reason, servers: [] });
      return true;
    }
    sendJson(response, 200, {
      available: true,
      servers: found.servers.map(({ port, command, cwd: serverCwd }) => ({ port, command, cwd: serverCwd })),
    });
    return true;
  }
  if (url.pathname === "/api/preview" && request.method === "POST") {
    const body = await readJsonBody(request);
    const record = bodyRecord(body);
    const cwd = await resolveWithinRoots(typeof record.cwd === "string" ? record.cwd : "", "/", config.roots);
    if (!cwd.ok) return sendPathFailure(response, cwd);
    if (!(await doorReady())) {
      sendJson(response, 409, {
        error: "This computer's preview door is not set up. Run `npx tavi-host pair` on it once; it adds the door.",
        doorMissing: true,
      });
      return true;
    }
    const opened = await previews.open({
      deviceId: deviceIdOf(request, config, devices),
      port: record.port,
      cwd: cwd.path,
    });
    if (!opened.ok) {
      sendJson(response, opened.status, { error: opened.error });
      return true;
    }
    const { preview, ticket } = opened.opened;
    sendJson(response, 201, {
      id: preview.id,
      port: preview.port,
      doorPort: config.previewDoorPort,
      cookieName: TICKET_COOKIE,
      ticket,
    });
    return true;
  }
  if (url.pathname === "/api/preview/stop" && request.method === "POST") {
    const body = await readJsonBody(request);
    const record = bodyRecord(body);
    const cwd = await resolveWithinRoots(typeof record.cwd === "string" ? record.cwd : "", "/", config.roots);
    if (!cwd.ok) return sendPathFailure(response, cwd);
    const port = validPort(record.port);
    if (port === undefined) {
      sendJson(response, 400, { error: "port must be a number between 1 and 65535." });
      return true;
    }
    const stopped = await stopProjectServer(cwd.path, port, config.roots, withOwnPortsExcluded(discovery, config));
    if (!stopped.ok) {
      sendJson(response, stopped.status, { error: stopped.error });
      return true;
    }
    sendJson(response, 200, { stopped: true, pid: stopped.pid, command: stopped.command });
    return true;
  }
  const previewSessionMatch = url.pathname.match(/^\/api\/preview\/([a-f0-9]{16})(\/keepalive)?$/);
  if (previewSessionMatch) {
    const id = previewSessionMatch[1] ?? "";
    const deviceId = deviceIdOf(request, config, devices);
    if (previewSessionMatch[2] && request.method === "POST") {
      const preview = previews.touch(id, deviceId);
      if (!preview) {
        sendJson(response, 404, { error: "That preview is no longer open." });
        return true;
      }
      const listening = await previews.listening(preview);
      sendJson(response, 200, { id, port: preview.port, listening });
      return true;
    }
    if (!previewSessionMatch[2] && request.method === "DELETE") {
      if (!previews.close(id, deviceId)) {
        sendJson(response, 404, { error: "That preview is no longer open." });
        return true;
      }
      response.writeHead(204).end();
      return true;
    }
  }
  return false;
};

// The host never offers (or stops) itself: its API and door ports are out.
function withOwnPortsExcluded(
  discovery: (DiscoveryDeps & { kill?: (pid: number) => void }) | undefined,
  config: HostConfig,
): DiscoveryDeps & { kill?: (pid: number) => void } {
  const base = discovery ?? defaultDiscoveryDeps();
  return {
    ...base,
    exclude: {
      pids: base.exclude?.pids ?? [],
      ports: [...(base.exclude?.ports ?? []), config.port, config.previewPort],
    },
  };
}

// The host's own token acts as one pseudo-device; a paired phone is itself.
function deviceIdOf(request: IncomingMessage, config: HostConfig, devices: DeviceRegistry): string {
  const token = bearerToken(request);
  if (isAuthorized(token, config.token)) return "host";
  return devices.authorize(token ?? "")?.id ?? "unknown";
}
