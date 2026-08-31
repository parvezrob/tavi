# Herdr integration notes

**Status:** verified live against herdr 0.7.5, socket protocol 17 (2026-08-25).
Host-side implementation: `apps/host/src/herdr.ts` (request/response) and `apps/host/src/herdr-events.ts` (event feed). This file records the externally-observed contract and the traps that cost debugging time; the bundled schema is authoritative: `herdr api schema --json`.

## Socket API basics

- Unix socket at `~/.config/herdr/herdr.sock` (override: `MOCHA_HERDR_SOCKET`).
- Newline-delimited JSON: `{id, method, params}` → `{id, result}` or `{id, error: {code, message}}`.
- Gate every integration on `ping` → `result.protocol === 17`. An unexpected protocol must degrade to "unavailable", never mis-parse.
- Surface `error.message` to callers — it carries actionable detail (e.g. `agent_name_taken` explains which pane owns the name).

## Methods Mocha uses

| Method | Params | Result shape (verified) |
| --- | --- | --- |
| `ping` | `{}` | `{type: "pong", version, protocol}` |
| `agent.list` | `{}` | `{type: "agent_list", agents: [...]}` — pane_id, agent, agent_status, cwd, terminal_title_stripped, workspace_id, tab_id, focused, revision |
| `agent.read` | `{target, source, lines, format}` | `{type: "pane_read", read: {text, truncated, ...}}` — the text is in `result.read.text` |
| `agent.prompt` | `{target, text}` | ack; **text appends to whatever is already typed in the agent's composer** |
| `agent.start` | `{name, kind, pane_id}` | `{type: "agent_started", agent, argv}` — see traps below |
| `tab.create` | `{cwd?, label?, workspace_id?, focus?, env?}` | `{type: "tab_created", tab: {tab_id, ...}, root_pane: {pane_id, ...}}` |
| `workspace.list` | `{}` | `{type: "workspace_list", workspaces: [{workspace_id, number, label, focused, pane_count, tab_count, active_tab_id, agent_status}]}` |
| `tab.list` | `{}` | `{type: "tab_list", tabs: [{tab_id, workspace_id, number, label, focused, pane_count, agent_status}]}` — all tabs across workspaces; group client-side |
| `tab.close` | `{tab_id}` | `{type: "ok"}` |
| `events.subscribe` | `{subscriptions: [...]}` | `{type: "subscription_started"}`, then a stream of `{data, event}` lines on the same connection |

CLI attach used by the terminal bridge: `herdr agent attach <pane_id>` (option `--takeover` exists; Mocha does not use it).

## Event subscription semantics (hard-won)

- Subscriptions are an internally tagged enum: `{type: "pane.created"}` etc. Full variant list comes back in the error message if you send a bogus type.
- `pane.agent_status_changed` is **per-pane** (`pane_id` required, no wildcard). Maintain one subscription per known agent pane and rebuild the set when panes change.
- `pane.created`, `pane.closed`, `pane.exited`, `pane.agent_detected`, `pane.updated` work **globally** (no pane_id).
- **`pane.agent_detected` is mandatory.** An agent started inside an already-open pane fires only this event — without it, a freshly started claude/codex is invisible to the feed (live bug, fixed in `de26850`).
- Events replay recent history on subscribe; treat events as change *triggers* and re-read `agent.list` for truth (herdr is the sole state authority; snapshots can never miss a removal).
- A rejected subscription (e.g. a pane vanished between list and subscribe) should rebuild against a fresh list.

## agent.start traps

- `name` must be **globally unique** across live agents; `kind` is the agent type (`claude`, `codex`). Using the kind as the name collides as soon as a second agent of that kind exists (`agent_name_taken`). Mocha appends a random suffix.
- A pane fresh out of `tab.create` answers `"agent target pane ... is not an available shell"` until its shell boots (~1–2 s). Retry briefly; on final failure close the orphan tab so nothing invisible lingers.

## Shared-terminal sizing

A pane clamps to the smallest attached client. While a phone (~41 cols) is attached, the pane is narrow on the Mac too — inherent to shared terminals. Mocha's mitigation: on phone detach the held attachment immediately claims a 250×80 grid so the desktop clamp wins within a second, while the v2 resume window stays available (`apps/host/src/attachment.ts`).

## Reported agents (plain terminals)

- herdr will not attach a pane that has no agent (`agent.attach` → `agent_not_found`) and has no shell kind. `pane.report_agent {pane_id, source, agent, state}` lets Mocha declare one: a pane reported as `agent: "shell", state: "idle", source: "mocha"` lists in `agent.list` with that kind and status, and `agent attach` / the host pty bridge accept it. Verified live 2026-08-31.
- herdr keeps a reported state: running commands in the pane did not flip `idle` to `working`/`done`, and the events feed carries the reported kind. A terminal therefore reads honestly as idle. Not yet verified: what happens if a real agent is later started by hand inside a reported pane.

