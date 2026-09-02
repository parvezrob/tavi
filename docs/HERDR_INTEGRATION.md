# Herdr integration notes

**Status:** verified live against herdr 0.7.5 / protocol 17 (2026-08-25) and herdr 0.8.2 / protocol 20 (2026-09-01: ping, workspace/tab/agent lists, session.snapshot, agent.read, tab.create, pane.report_agent, agent.send_keys, tab.close all answer with the same shapes; 0.8.2 adds fields such as `agent_session`, `foreground_cwd`, `capabilities`). `herdr server` runs headless with no PTY (brew services / launchd / systemd) — the old "needs a tmux session" note was about 0.7.x.
Host-side implementation: `apps/host/src/herdr.ts` (request/response) and `apps/host/src/herdr-events.ts` (event feed). This file records the externally-observed contract and the traps that cost debugging time; the bundled schema is authoritative: `herdr api schema --json`.

## Socket API basics

- Unix socket at `~/.config/herdr/herdr.sock` (override: `TAVI_HERDR_SOCKET`).
- Newline-delimited JSON: `{id, method, params}` → `{id, result}` or `{id, error: {code, message}}`.
- Gate on `ping` → `result.protocol >= MIN_PROTOCOL` (17, the oldest verified) **and on the shape of `agent.list`** (an `agents` array whose entries carry `pane_id` and `agent_status`). A newer herdr that keeps the shape works without a Tavi release (owner decision 2026-09-01: no lockstep upgrades); one that breaks it degrades to "unavailable" with `npx tavi-host@latest pair`; too old says `brew upgrade herdr`. Never mis-parse. After each herdr release worth noting, re-run the live probe of every method the host uses and update the status line above.
- Surface `error.message` to callers — it carries actionable detail (e.g. `agent_name_taken` explains which pane owns the name).

## Methods Tavi uses

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
| `pane.report_agent` | `{pane_id, source, agent, state}` | ack — see "Reported agents" |
| `pane.release_agent` | `{pane_id, source, agent}` | ack — drops that source's report (#66) |
| `pane.get` | `{pane_id}` | `{type: "pane_info", pane: {pane_id, agent, agent_status, agent_session?, ...}}`; error `pane_not_found` when gone |
| `events.subscribe` | `{subscriptions: [...]}` | `{type: "subscription_started"}`, then a stream of `{data, event}` lines on the same connection |

CLI attach used by the terminal bridge: `herdr agent attach <pane_id> --takeover` — always with the flag (2026-09-02): herdr keeps a departed client registered for a moment, so a fresh attach right after a drop or after the host disposed the retained pty was refused with "already has an attached client" and the phone showed a live Claude session as ended (owner, robin-PC). Tavi is the only external attach client a pane has, so taking over is always right.

## Event subscription semantics (hard-won)

- Subscriptions are an internally tagged enum: `{type: "pane.created"}` etc. Full variant list comes back in the error message if you send a bogus type.
- `pane.agent_status_changed` is **per-pane** (`pane_id` required, no wildcard). Maintain one subscription per known agent pane and rebuild the set when panes change.
- `pane.created`, `pane.closed`, `pane.exited`, `pane.agent_detected`, `pane.updated` work **globally** (no pane_id).
- **`pane.agent_detected` is mandatory.** An agent started inside an already-open pane fires only this event — without it, a freshly started claude/codex is invisible to the feed (live bug, fixed in `de26850`).
- Events replay recent history on subscribe; treat events as change *triggers* and re-read `agent.list` for truth (herdr is the sole state authority; snapshots can never miss a removal).
- A rejected subscription (e.g. a pane vanished between list and subscribe) should rebuild against a fresh list.

## agent.start traps

- `name` must be **globally unique** across live agents; `kind` is the agent type (`claude`, `codex`). Using the kind as the name collides as soon as a second agent of that kind exists (`agent_name_taken`). Tavi appends a random suffix.
- A pane fresh out of `tab.create` answers `"agent target pane ... is not an available shell"` until its shell boots (~1–2 s). Retry briefly; on final failure close the orphan tab so nothing invisible lingers.

## Shared-terminal sizing

**Pane size is last-writer-wins, not smallest-client (verified live 2026-08-31, #44).** An external `agent attach` sets the pane's *terminal* size; herdr does not restore it when that client leaves, and its own viewer displays a fixed layout rect onto whatever the terminal is. While a phone (~44 cols) is attached the Mac is phone-sized too — inherent to a shared pty. On detach Tavi resizes the held pty back to the pane's viewer rect (`session.snapshot` → `layouts[].panes[].rect`, e.g. 174×49), which is exactly what the Mac displays. The earlier 250×80 "desktop-scale" claim was wrong here: it left the Mac looking at the top-left of an 80-row terminal with Claude's prompt off-screen. When herdr cannot say what the Mac shows, the size is left alone (#53 removed the old 250×80 tmux claim with the tmux lane). **The hand-back waits out a grace window (`DETACH_GRACE_MS`, 8 s, #63):** a phone that drops and re-claims inside it — a network blip, a path change, a host too busy to answer — never causes a resize at all. Without it the pty went 41 → 174 → 41 columns inside a second and the agent's TUI reflowed the transcript into garbage on the phone (owner, 2026-09-02). A real detach still returns the pane to the Mac 8 s later.

## Reported agents (plain terminals)

- herdr will not attach a pane that has no agent (`agent.attach` → `agent_not_found`) and has no shell kind. `pane.report_agent {pane_id, source, agent, state}` lets Tavi declare one: a pane reported as `agent: "shell", state: "idle", source: "tavi"` lists in `agent.list` with that kind and status, and `agent attach` / the host pty bridge accept it. Verified live 2026-08-31.
- herdr keeps a reported state: running commands in the pane did not flip `idle` to `working`/`done`, and the events feed carries the reported kind. A terminal therefore reads honestly as idle.
- **A report pins the label for the pane's life (#66, verified live 2026-09-02).** Start `claude` inside a reported Terminal and herdr *does* detect it — `agent_session.agent = "claude"`, title "Claude Code", `herdr agent explain` names the rule — but `agent` stays `"shell"` and `agent_status` stays the reported `idle`; re-reporting as `claude` does not help. `pane.release_agent {pane_id, source: "tavi", agent: "shell"}` drops the report and herdr's own detection labels the pane within ~2–4 s (`agent: "claude"`, status from the screen: idle/working/done/blocked). In between the pane is in **no list at all** (a 2 s gap). When the detected agent exits, the pane leaves `agent.list` while still existing (`pane.get` answers); reporting shell again brings the Terminal back. The host's events feed does both (`herdr-events.ts reconcileShellPanes`), carries the last known row through the gap, and the terminal upgrade retries `findAgent` for 3 s so a reconnect in the gap is not a 404. `agent.list` items carry `agent_session.agent` — Tavi exposes it as `detectedAgent` only when it differs from `agent`.
- **`report_agent state: idle` after the pane has worked reads back as `done`.** A Terminal that hosted an agent would say "done" forever; the host maps `done` → `idle` for `agent: "shell"` (a shell has no task to finish). `state: working` does apply.


## Rendering a pane from snapshots instead of attaching (#44 step-2 spike, 2026-09-01)

Measured live against herdr protocol 17 so the spike is not repeated:

- `agent.read` / `pane.read` with `source: "visible", format: "ansi", strip_ansi: false` returns the Mac's exact viewport with full SGR attributes (256-color, bold, dim, box drawing), one `\r\n` per row, ~100 ms per socket round trip. Good enough to paint a read-only mirror. The `revision` field in the read result stays `0`; it is not an output counter.
- **There is no push signal for output.** `pane_output_changed` is in the `EventKind` enum but is not a subscribable type and never arrived on any of the 25 subscribable types. `pane.updated` fires on state/metadata changes only, not on output. `pane.output_matched` (regex/substring) fires **once** at subscribe with the matching read (`format: "text"` even with `strip_ansi: false`) and never again. `pane.scroll_changed` fires only when scrollback grows past the viewport; it carries `viewport_rows`. A mirror therefore has to poll.
- **No cursor position** is exposed anywhere — not in reads, `session.snapshot`, or events. `session.snapshot` gives each pane's `rect` in cells (e.g. 171×46).
- One request per socket connection: herdr closes the socket after the response; only `events.subscribe` keeps it open. An unscoped `pane.updated` subscription replays the whole pane history at ~100 ms per event (138 events / 15 s on the owner Mac) — always scope subscriptions by `pane_id` where the schema allows.

Conclusion recorded on #44: a snapshot mirror would be a ~200 ms-laggy, cursorless, `send_keys`-only view. Not built; the pty attach stays. The Mac-stays-full-size wish is step 3 (a viewer-only attach in herdr) or a compose-mode-only mirror.
