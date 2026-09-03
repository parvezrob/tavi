import { AGENT_KIND_NAMES, SHELL_KIND } from "../agent-kinds.js";
import { readJsonBody, type Route, sendJson } from "../http.js";
import { isWithinRoots, normalizeProjectPath } from "../projects.js";
import { safeSessionId } from "../validation.js";

export const herdrRoutes: Route = async (url, request, response, context) => {
  const { config, herdr, projects, agentKinds } = context;

  if (url.pathname === "/api/herdr/tree" && request.method === "GET") {
    if (!herdr) {
      sendJson(response, 404, { error: "Herdr integration is not configured on this host." });
      return true;
    }
    const tree = await herdr.listTree();
    if (!tree.available) {
      sendJson(response, 503, { error: tree.reason });
      return true;
    }
    sendJson(response, 200, { workspaces: tree.workspaces });
    return true;
  }

  const tabCloseMatch = url.pathname.match(/^\/api\/herdr\/tabs\/([^/]+)$/);
  if (tabCloseMatch && request.method === "DELETE") {
    if (!herdr) {
      sendJson(response, 404, { error: "Herdr integration is not configured on this host." });
      return true;
    }
    const tabId = safeSessionId(tabCloseMatch[1] || "");
    const result = await herdr.closeTab(tabId);
    if (!result.closed) {
      sendJson(response, 503, { error: result.reason });
      return true;
    }
    sendJson(response, 200, { closed: true, tabId });
    return true;
  }

  // Rename a tab (#55): the user's own name for the task becomes the
  // pane's identity on the phone. Herdr owns the truth; the new label
  // reaches every phone through the events feed's refresh.
  if (tabCloseMatch && request.method === "PATCH") {
    if (!herdr) {
      sendJson(response, 404, { error: "Herdr integration is not configured on this host." });
      return true;
    }
    const tabId = safeSessionId(tabCloseMatch[1] || "");
    const body = await readJsonBody(request);
    const record = typeof body === "object" && body !== null ? (body as Record<string, unknown>) : {};
    const label = typeof record.label === "string" ? record.label.trim() : "";
    if (!label || label.length > 120) {
      sendJson(response, 400, { error: "label must be 1–120 characters." });
      return true;
    }
    const result = await herdr.renameTab(tabId, label);
    if (!result.renamed) {
      sendJson(response, 503, { error: result.reason });
      return true;
    }
    sendJson(response, 200, { renamed: true, tabId, label: result.label });
    return true;
  }

  if (url.pathname === "/api/herdr/tabs" && request.method === "POST") {
    if (!herdr) {
      sendJson(response, 404, { error: "Herdr integration is not configured on this host." });
      return true;
    }
    const body = await readJsonBody(request);
    const record = typeof body === "object" && body !== null ? (body as Record<string, unknown>) : {};
    const agent = typeof record.agent === "string" ? record.agent : undefined;
    if (agent !== undefined && !AGENT_KIND_NAMES.includes(agent)) {
      sendJson(response, 400, { error: `agent must be one of: ${AGENT_KIND_NAMES.join(", ")}.` });
      return true;
    }
    // herdr accepts a kind that is not installed and hands back a tab whose
    // launch has already failed — a dead pane that lists as nothing. Refuse
    // up front instead, with the reason the picker already shows.
    if (agent !== undefined) {
      const kind = (await agentKinds.list()).find((entry) => entry.kind === agent);
      if (kind && !kind.installed) {
        sendJson(response, 400, { error: `${kind.label} is not installed on this Mac.` });
        return true;
      }
    }
    // `cwd` is required (#24). It used to be optional, which is exactly how
    // phone-created agents ended up in the host user's home directory.
    if (typeof record.cwd !== "string") {
      sendJson(response, 400, { error: "cwd is required: choose the project folder to work in." });
      return true;
    }
    const candidate = normalizeProjectPath(record.cwd);
    if (!candidate.ok) {
      sendJson(response, 400, { error: candidate.reason });
      return true;
    }
    // Outside the configured roots the phone must say so explicitly, which
    // it only does after asking the person a second time.
    if (!isWithinRoots(candidate.path, config.roots) && record.allowOutsideRoots !== true) {
      sendJson(response, 400, {
        error: "That folder is outside your project roots. Confirm the custom location to continue.",
        outsideRoots: true,
      });
      return true;
    }
    const result = await herdr.createTab({
      agent,
      cwd: candidate.path,
      label: agent === SHELL_KIND ? "tavi terminal" : agent ? `tavi ${agent}` : "tavi",
    });
    if (!result.created) {
      sendJson(response, 503, { error: result.reason });
      return true;
    }
    // Only a folder that actually launched something earns a place in the
    // picker's recent list.
    projects.remember(candidate.path);
    sendJson(response, 201, { paneId: result.paneId, tabId: result.tabId });
    return true;
  }
  return false;
};
