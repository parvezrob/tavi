import { parseClaudeHookEvent } from "../attention.js";
import type { DialogDecision } from "../herdr-types.js";
import { bodyRecord, readJsonBody, type Route, sendHerdrUnconfigured, sendJson } from "../http.js";
import { mergeRecentProjects } from "../projects.js";
import { clamp, safeSessionId } from "../validation.js";

const MAX_PREVIEW_CHARACTERS = 4_096;
const MAX_PROMPT_CHARACTERS = 16_384;

export const agentRoutes: Route = async (url, request, response, context) => {
  const { config, herdr, listWorkspaces, attention, projects, agentKinds } = context;

  // Everything the New Agent picker needs in one call (#24): the folders
  // agents are living in now plus this host's remembered choices, the
  // browsable roots, the roots themselves so the phone knows which custom
  // path will need the extra confirmation, and which agent kinds this Mac
  // can actually launch.
  if (url.pathname === "/api/projects" && request.method === "GET") {
    const [agents, workspaces, kinds] = await Promise.all([
      herdr ? herdr.listAgents() : undefined,
      listWorkspaces(config.roots),
      agentKinds.list(),
    ]);
    const agentCwds = agents?.available ? agents.agents.map((agent) => agent.cwd) : [];
    sendJson(response, 200, {
      recent: mergeRecentProjects(projects.list(), agentCwds, config.roots),
      workspaces,
      roots: config.roots,
      agents: kinds,
    });
    return true;
  }

  const previewMatch = url.pathname.match(/^\/api\/agents\/([^/]+)\/preview$/);
  if (previewMatch && request.method === "GET") {
    if (!herdr) return sendHerdrUnconfigured(response);
    const paneId = safeSessionId(previewMatch[1] || "");
    const requestedLines = Number.parseInt(url.searchParams.get("lines") || "12", 10);
    const lines = Number.isFinite(requestedLines) ? clamp(requestedLines, 1, 50) : 12;
    const result = await herdr.readAgent(paneId, lines);
    if (!result.available) {
      sendJson(response, 503, { error: result.reason });
      return true;
    }
    sendJson(response, 200, {
      paneId,
      lines,
      preview: result.preview.slice(0, MAX_PREVIEW_CHARACTERS),
    });
    return true;
  }

  const dialogMatch = url.pathname.match(/^\/api\/agents\/([^/]+)\/dialog$/);
  if (dialogMatch && request.method === "GET") {
    if (!herdr) return sendHerdrUnconfigured(response);
    const paneId = safeSessionId(dialogMatch[1] || "");
    const result = await herdr.readDialog(paneId);
    if ("available" in result) {
      sendJson(response, 503, { error: result.reason });
      return true;
    }
    sendJson(response, 200, {
      paneId,
      present: result.present,
      ...(result.present ? { dialog: result.dialog } : {}),
    });
    return true;
  }

  const decisionMatch = url.pathname.match(/^\/api\/agents\/([^/]+)\/decision$/);
  if (decisionMatch && request.method === "POST") {
    if (!herdr) return sendHerdrUnconfigured(response);
    const paneId = safeSessionId(decisionMatch[1] || "");
    const body = await readJsonBody(request);
    const record = bodyRecord(body);
    const rawDecision = record.decision;
    // "approve" / "deny", or { decision: "option", option: N } to pick a
    // specific numbered choice.
    let decision: DialogDecision | undefined;
    if (rawDecision === "approve" || rawDecision === "deny") {
      decision = rawDecision;
    } else if (rawDecision === "option") {
      const option = record.option;
      if (typeof option === "number" && Number.isInteger(option) && option > 0) {
        decision = { option };
      }
    }
    if (!decision) {
      sendJson(response, 400, {
        error: 'decision must be "approve", "deny", or "option" with a positive integer option.',
      });
      return true;
    }
    // Trust gate, two layers. Outer (here): at least one authority must flag
    // this agent as waiting — the Claude hook overlay (Claude's own fact) or
    // herdr's live screen status. Inner (herdr.decideAgent): the pane is
    // re-read immediately before any key is sent and a real permission dialog
    // must still parse out of it, or nothing fires. The inner re-read is what
    // actually guarantees we never answer a stale card, so the outer layer is
    // a cheap "is this plausibly waiting" check, not the safety — which is why
    // it accepts either authority (some dialogs, e.g. the trust-folder prompt,
    // are herdr-blocked but never emit a PermissionRequest hook).
    const lookup = await herdr.findAgent(paneId);
    if (!lookup.available) {
      sendJson(response, 503, { error: lookup.reason });
      return true;
    }
    const overlayBlocked = attention?.isBlocked(lookup.agent?.sessionRef) ?? false;
    const herdrBlocked = lookup.agent?.status === "blocked";
    if (!overlayBlocked && !herdrBlocked) {
      sendJson(response, 409, {
        error: "This agent is not waiting for a decision right now.",
        stale: true,
      });
      return true;
    }
    const result = await herdr.decideAgent(paneId, decision);
    if (!result.decided) {
      sendJson(response, result.stale ? 409 : 503, {
        error: result.reason,
        ...(result.stale ? { stale: true } : {}),
      });
      return true;
    }
    sendJson(response, 200, { decided: true, sent: result.sent, paneId });
    return true;
  }

  const promptMatch = url.pathname.match(/^\/api\/agents\/([^/]+)\/prompt$/);
  if (promptMatch && request.method === "POST") {
    if (!herdr) return sendHerdrUnconfigured(response);
    const paneId = safeSessionId(promptMatch[1] || "");
    const body = await readJsonBody(request);
    const text =
      typeof body === "object" && body !== null && "text" in body && typeof body.text === "string"
        ? body.text
        : undefined;
    if (!text || text.length > MAX_PROMPT_CHARACTERS) {
      sendJson(response, 400, { error: "Prompt text is required and must stay under the size limit." });
      return true;
    }
    const result = await herdr.promptAgent(paneId, text);
    if (!result.submitted) {
      sendJson(response, 503, { error: result.reason });
      return true;
    }
    sendJson(response, 202, { submitted: true, paneId });
    return true;
  }

  if (url.pathname === "/api/hooks/claude" && request.method === "POST") {
    const event = parseClaudeHookEvent(await readJsonBody(request));
    if (!event) {
      sendJson(response, 400, { error: "A hook event needs hook_event_name and session_id." });
      return true;
    }
    attention?.report(event);
    sendJson(response, 200, { ok: true });
    return true;
  }

  if (url.pathname === "/api/agents" && request.method === "GET") {
    if (!herdr) {
      sendJson(response, 200, {
        provider: "herdr",
        available: false,
        reason: "Herdr integration is not configured on this host.",
        agents: [],
      });
      return true;
    }
    const result = await herdr.listAgents();
    if (result.available && attention) {
      sendJson(response, 200, {
        ...result,
        agents: result.agents.map((agent) =>
          attention.isBlocked(agent.sessionRef) ? { ...agent, status: "blocked", authority: "claude-hook" } : agent,
        ),
      });
      return true;
    }
    sendJson(response, 200, result);
    return true;
  }
  return false;
};
