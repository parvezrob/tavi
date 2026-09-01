# Current session

> Every agent starts here. This file holds the live state of the project *right now* and the next piece of work. Update it before ending a session (or at any significant milestone); move the previous state into [`handoffs.md`](./handoffs.md). Keep it short — details belong in the linked docs.

**Last updated:** 2026-09-02 (session closed — #50 built, reviewed, home reshaped twice on real screens; **#50 stays open: owner discusses the home design with Fable 5.1 next, then the remaining live steps**)

## Next work

**#50 multi-host — owner + Fable 5.1 design discussion first, then finish the live pass.** Everything is built and on the phone (see the 2026-09-02 handoffs entry for the full trail: `5abb184` core → `33e8c5d` cold-review pass → `665643a` home v2 chips → `f58adf2` needs-you rows). The owner still feels the home isn't right and wants to talk it through before closing; the decision page comparing the layouts is https://claude.ai/code/artifact/a1d8e9aa-1c47-4c5d-b28d-3274dd45f25f, the references are `docs/assets/orca-mobile-reference.png`, `docs/assets/concept-session-stack.png`, and T3 Code mobile (flat threads, environment as a quiet trailing label, Environments sheet behind ⋯). What the home is now: chip strip filter (`All · ● MacBook Air · ● robin-PC`), needs-you as one striped block of compact rows, one project list by state with the computer named on each header, `PairedHost.alias`/`shortName`, per-computer sheet with `Live · 40 ms · 8 agents · 5 waiting`.

**Remaining acceptance (after the design settles):** block an agent on robin-PC → surfaces on top as `robin-PC · folder`, answer via decision sheet (header names the computer); New Agent → picks robin-PC → create (**also #48's last verification** — agent cards + create-agent on Linux); terminals on both; Jump-to across computers; `npx tavi-host devices revoke` on one host → only its chip turns Unpaired (Pair again / Remove), the other keeps working; Mac asleep → chip Offline + one banner, last-known cards stay. Then close #50 and #48.

**Known display truth to keep in mind:** the Mac's five "waiting" agents are herdr-restored `claude --resume` panes with blank screens — herdr itself says `blocked`, no dialog, empty preview. Tavi reports it honestly; closing those tabs on the Mac clears it. Possibly a herdr bug (blank restored pane ⇒ blocked) worth filing upstream.

**Review findings deliberately not done (owner call):** accessibility identifiers stay pane-only (test hooks; UI suite is single-host); computers keep pairing order even when the first is asleep; `Live · n ms` stays on the chip-era surfaces; no `.id(terminalHostId)` on the terminal destination (jumping keeps composer state).

**After #50:** #25 + #61 + #57 (diff glance → files-mentioned → project files, one read-only file endpoint), #58 dev-server preview, #59 worktrees. #54 P3 brand moments unblocked. #37 App Store epic gates any submission. Phase E push payloads must carry `hostId` + `paneId` (`AgentTarget`, noted in code).

**Publishing rule (owner + agent, 2026-09-01):** the agent bumps `apps/host/package.json` + `VERSION` only when it says a release is worth publishing; the owner runs `cd apps/host && npm publish` in Terminal.app (2FA; the auth URL is masked under Claude Code). Versions are immutable, propagate in 1–2 min, and every publish restarts every paired host. Nothing in #50 touched the host; no publish needed.

**Open owner decisions:** whether phones should stop accepting the shared host token; a hosted relay opt-in for people who bounce off Tailscale (docs/PRODUCT.md principle 2 says direct only; decide after testers); GitHub Actions publish job.

## Live state

- **Product:** Tavi by Farfield (Terminal Agent Vantage and Intervention). Repo `parvezrob/tavi`, checkout `~/Projects/tavi`. Host package `tavi-host` 0.1.9 on npm (Apache-2.0; everything else © Farfield). README quick start = `npx tavi-host pair`; the rest of the CLI: `doctor`, `update`, `devices [revoke]`, `install-service`/`uninstall-service`, `install-claude-hooks`, `uninstall`.
- **Owner Mac:** host runs from the checkout as launchd `com.farfield.tavi.host` (deploy: `npm run build && npm run service:install`, then `/api/health`; it reported 0.1.6 at session end — the service predates the 0.1.9 source, redeploy when convenient); herdr 0.8.2 under `brew services start herdr` (headless; no tmux anywhere); Claude hooks installed. Phone runs `44216c5` as `com.farfield.tavi`, paired to the Mac (device `35348beb105b`). Tailscale Serve → :8787. Checkout hosts never self-update (by design).
- **Owner ubuntu (`robin-PC`):** paired again 2026-09-01 late via `npx tavi-host pair` on the clean slate; live at 6 ms; two Claude Code agents in `~/Documents/Projects/portfolioai` at the time.
- **Phone runs `f58adf2` (needs-you rows build); both the Mac and robin-PC (ubuntu) are paired** (#50). Profile expires 2026-09-08.
- **Host ↔ herdr:** gate is protocol ≥ 17 + `agent.list` shape (`docs/HERDR_INTEGRATION.md`); verified on 17 (0.7.5) and 20 (0.8.2). `agent.read` sources `recent`/`visible`; digit keys select-and-confirm in Claude dialogs; `shift+tab` cycles modes.
- **Self-update / runtime:** `docs/DEVELOPMENT.md` "Self-update" (layout, launcher rollback, `TAVI_AUTO_UPDATE=off`, `TAVI_UPDATE_REGISTRY`, the fake-registry e2e recipe).
- **Needs-you fidelity (#22):** Claude hooks force `blocked · claude-hook` via `AttentionOverlay` until a resolution hook; #60 reconciler clears it when no dialog is on screen; phone adds 5 s hysteresis + stale banner. Hooks apply to **new** Claude sessions only.
- Prompt delivery: launch-pending retry, typing fallback via `send_keys`, post-prompt Enter nudge. Project roots from `TAVI_ROOTS` (default: existing of `~/Code`, `~/Projects`, `~/Developer`, `~/Documents`) — picker list and creation guardrail; no roots ⇒ every create needs confirmation.
- Live UI tests: export `TEST_RUNNER_TAVI_DEV_HOST/TOKEN` (token via `npm run -s token` in apps/host); they create disposable agents via `knownProjectPath` + `allowOutsideRoots` and clean up; check `xcresulttool` for skipped vs passed. Verification rule: for anything a person sees, look (screenshot / exact strings) — green suites have missed visible breakage three times.
- Open issues: #25, #27–#29 (parked), #37 epic, #39 test seam, #44 (owner decision), #47 (acceptance timing only), #48 (Linux cards/create + defaults), #50 next, #52 polish, #54 P3, #57–#59, #61.
- Security hygiene #31–#36 shipped; App Store readiness milestone + #37 gate any submission; `codebase-scan.html` is an audit input, never the tracker.
