# Mocha build roadmap

**Status:** Active build plan — this is the execution order
**Updated:** 2026-08-25
**Owner decision:** Mocha builds its intelligent layer on Herdr (verified: herdr 0.7.5, socket API protocol 17). The tmux lane was removed on 2026-08-31 (#53) — herdr is the only backend. This roadmap supersedes the phase ordering in [`IMPLEMENTATION_PLAN.md`](./IMPLEMENTATION_PLAN.md); the PRD, screen map, and development principles remain the product and quality authority.

Each phase has an exit gate. Do not start the next phase's feature work before the gate passes, except for trivial fixes. Every item becomes a GitHub issue when work starts.

## Already shipped (not part of the plan)

Real-time terminal rendering (embedder-driven draws), off-main-thread output pump, keyboard/resize grid self-healing, touch scrollback scrolling (MVP feel), default iOS keyboard, dedicated low-latency tmux socket (`-L mocha`, escape-time 10, mouse on, no chrome), Ctrl-S flow-control fix, tight backpressure buffers, `SessionBackend` seam, read-only Herdr provider (`GET /api/agents` with status + provenance), live simulator UI-test harness (typing echo, keyboard-toggle streaming, scroll health).

## Phase A — Always-on and reconnect (reliability is the product) ✅ COMPLETE 2026-08-25

All four items shipped (issues #12, #13, #14, #4/#5): installed launchd host service with auto-restart; network-path-aware sub-second reconnect with honest states; `mocha.v2` transport with persistent attachments, binary frames, and exact-offset resume (verified: 0 lost / 0 duplicated bytes across a mid-stream hard drop). Exit gate passed on the physical iPhone 12 Pro: fast Wi-Fi ↔ cellular reconnect to live output; lock/unlock, app switching, and repeated surface create/destroy all crash-free.

1. Host runs as the installed launchd service with auto-restart; dev watch mode becomes optional. *(the dev host silently dying has already cost us debugging time)*
2. Fast reconnect: network-path-change detection on the phone, sub-second retry, honest connection states; reconnect restores the exact session.
3. Transport v2 on `mocha.v2` protocol: binary output frames, sequence numbers with resume, so reconnects continue mid-stream instead of replaying or gapping.
4. Release-blocking device gates: Ghostty surface teardown stress (issue #5) and the physical-device checklist (issue #4) — create/destroy, lock/unlock, background/foreground, session switching.

**Exit gate:** Wi-Fi ↔ cellular flip reconnects to live output in under 1 second; repeated lifecycle stress passes on the physical iPhone with no crash and no lost/duplicated input.

## Phase B — Herdr control plane (host + protocol) ✅ COMPLETE 2026-08-25

All five items shipped and live-verified (issues #15, #16): agents are attachable terminal targets via `herdr agent attach`; the events feed pushes full-status snapshots sub-second (idle→working→blocked→done timelines captured on the wire and rendered on the phone); bounded previews serve Herdr's own pane text; `agent.prompt` submitted to a live pane and the reply plus status transitions arrived within ~2s; the tmux lane stayed intact throughout, and Herdr restarts degraded honestly twice in live testing. Exit gate passed: tapping an agent on the phone lands in its exact pane. Bonus beyond plan (#17): new Herdr tabs (Claude/Codex/empty) can be created from the phone.

1. Attach to a specific Herdr agent (`herdr agent attach <target>`) through the existing pty bridge; agents in `/api/agents` become attachable terminal targets.
2. Live attention events: host subscribes to `events.subscribe` (agent status changes) and pushes them to the phone over the WebSocket; no polling, no scraping.
3. Bounded safe previews via `agent.read` for session cards.
4. Structured prompt submission via `agent.prompt` (used by the composer in Phase C).
5. ~~tmux lane remains fully functional as the fallback for non-Herdr sessions~~ *Superseded: #26 took the lane off the home, #53 (2026-08-31) deleted it. Herdr down shows the degraded card and keeps retrying; every agent card still opens a real terminal.*

**Exit gate:** From the phone: agent list with live status; tapping an agent lands in its exact pane; a status change (working → blocked) appears on the phone within 2 seconds.

## Phase C — The real app (iOS product surface)

Target visuals: [`assets/agent-deck-v1-home-terminal.png`](./assets/agent-deck-v1-home-terminal.png) — the mockup predates #26; the shipped home groups computer → project → agents below the needs-you list.

1. Sessions home: `Needs you` / `Active` / `Recent` cards with agent identity, host, state colors, freshness, and safe preview — driven by Phase B data with provenance labels.
2. Focused terminal screen: header with session/host/provider identity, `Jump to` sheet over the Herdr workspace → tab hierarchy.
3. Multiline composer with deliberate send (the PRD's primary input mode) plus completed quick-key row (Shift-Tab, Ctrl modifier, Enter).
4. Terminal ergonomics: **font-size setting shipped 2026-08-31 (#51** — Settings → Terminal with a live Ghostty preview and the projected grid; pinch on the terminal writes the same persisted setting; optional Face ID app lock, default off. A smaller phone font gives the shared herdr pane on the Mac a bigger grid while attached, see #44). Still open: selection + copy/paste, scroll feel tuning (#10), hardware-keyboard pass.

Adopted 2026-08-26 after a competitor survey (t3code, Happy, Omnara, CodeAgent Mobile — owner decision), extending Phase C:

5. Approve/deny a waiting permission straight from the Needs-you card (#23) — the core intervention loop without entering the terminal.
6. Project picker for phone-created agents (#24) — recent project directories from the host; no more agents landing in `~`.
7. Read-only diff glance per agent (#25) — "what did it change", size-bounded, no mutating git operations.
8. **Shipped 2026-08-31** — project-grouped home (#26): needs-you stays a flat list on top; below it computer → project (agent `cwd` basename, "Home" for `~`) → running cards, then a compact card of done/idle rows with their status word. Project headers count waiting agents but never repeat them. The tmux card left the home; the whole tmux lane was then deleted the same day (#53).

Post-MVP backlog adopted the same day: Inbox (#27), snooze/settle triage (#28), session-handoff cue (#29). Multi-host is Phase D item 3; push notifications remain Phase E item 1. Deliberately rejected: cloud relay/accounts, on-phone code editing or file trees, model catalogs/API keys, phone-side git mutations, task boards, web client, telemetry.

**Exit gate:** Founder dogfood entirely from the phone: median under 5 seconds from app open to the correct session; 20 real interventions without opening the laptop (PRD MVP criteria).

## Phase D — Pairing and trust (replace the dev connection flow)

1. `mocha pair` on the host: QR with endpoint + fingerprint + single-use secret; scan-first flow per [`assets/agent-deck-v1-pairing-flow.png`](./assets/agent-deck-v1-pairing-flow.png).
2. Per-device revocable credentials in Keychain; paired-device list and revoke on the host.
3. Multi-host home with connection health, path, and latency (#50: one phone, several computers, grouped by computer; #26's project grouping nests under it).

**Exit gate:** A fresh phone pairs in under 2 minutes without documentation; revoking a device immediately cuts its access; the dev token flow is deleted.

## Phase E — Ambient attention and release

1. Push notifications for blocked/done transitions (requires the one deliberate cloud carve-out — APNs relay or equivalent — decided and documented at the start of this phase).
2. Live Activities / Dynamic Island for waiting sessions.
3. Beta hardening: crash-free ≥ 99.5%, chaos/network-flap suite in CI, demo mode, App Store review package per PRD.

**Exit gate:** External testers on TestFlight complete a week of interventions; notification-to-unblock loop works with the app closed.

## Working rules

- Reliability regressions block feature work in any phase.
- Herdr integration is capability-gated and kill-switchable; the terminal fallback is never allowed to break — every agent card opens a real terminal (the separate tmux lane was removed in #53).
- Physical-device verification is required for anything touching rendering, input, lifecycle, or networking.
- When this roadmap and reality disagree, update the roadmap in the same change.
