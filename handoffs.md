# Session handoffs

> Append-only log of completed work sessions, newest first. Each entry is what the *next* agent needs to know about that session: what shipped, what was learned, what was left open. The live starting point is always [`current-session.md`](./current-session.md); prune entries older than a few sessions — git history keeps everything.

## 2026-08-25 — Phases A and B, complete

**Shipped (commits `b545fe4` → `73ce984`):**
- Phase A (issues #12, #13, #14, gates #4/#5): launchd host service with auto-restart; network-path-aware sub-second reconnect (NWPathMonitor, honest `waitingForNetwork` state, 3 s connect deadline, 250 ms first retry); `mocha.v2` transport — persistent pty attachments, binary output frames, exact-offset resume (verified 0 lost / 0 duplicated bytes across a hard mid-stream drop). All lifecycle gates passed on the physical iPhone 12 Pro.
- Phase B (issues #15, #16, #17): Herdr agents attachable at `/api/agents/{pane}/terminal`; `/api/events` WS pushes full agent snapshots sub-second; bounded previews; one-shot `agent.prompt` (verified live — reply and status transitions within ~2 s); phone-created agent tabs (Claude/Codex) with unique-name + shell-boot-retry fixes; live Agents list + tap-to-pane on the phone. tmux fallback intact throughout.
- Post-gate fixes from owner field testing: agent-name collision, shell-not-ready race, orphan-tab cleanup, Herdr error text surfaced to the phone, detach size restore (Mac pane no longer stays phone-width after locking the phone).
- Knowledge moved into the repo: `docs/DEVELOPMENT.md`, `docs/HERDR_INTEGRATION.md`, transport v2 spec in `protocol/README.md`.

**Learned (recorded in the docs above):** Herdr per-pane status subscriptions with mandatory global `pane.agent_detected`; `agent.start` unique-name requirement; `result.read.text` shape; launchd needs an explicit UTF-8 LANG or tmux corrupts its field separator; `MOCHA_DEV_HOST` must be the Tailscale HTTPS URL; TEST_RUNNER_ vars must be exported; cwd drifts between shell calls — use absolute `cd`.

**Left open:** Phase C (next), issue #10 (scroll feel), issue #8 (unrelated PWA). Owner decisions of note: keep tmux as invisible backbone with Herdr as the featured brain; dev token flow acceptable until Phase D; "Empty tab" option removed from the phone until plain panes are listable.
