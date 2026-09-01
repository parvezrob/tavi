# Current session

> Every agent starts here. This file holds the live state of the project *right now* and the next piece of work. Update it before ending a session (or at any significant milestone); move the previous state into [`handoffs.md`](./handoffs.md). Keep it short — details belong in the linked docs.

**Last updated:** 2026-09-01 (evening session closed — Tavi by Farfield shipped end to end, `tavi-host` 0.1.9 on npm; **next: #50 multi-host**)

## Next work

**#50 multi-host — one phone, Mac + Linux at once, home grouped by computer.** Owner direction 2026-09-01: after the tester install, multi-device support. Read the issue (https://github.com/parvezrob/tavi/issues/50) — it has the scope; the host side needs nothing new (each host is independent; #46 gave every host its own device credential). App side: `PairedHostRecord` → a set with one Keychain credential per host id; one `AgentDirectory` per host running concurrently, each with its own live/stale/offline/revoked state; home = needs-you across all hosts on top, then a group per computer (name + health + latency) with #26's project grouping inside; terminal, Jump-to, New Agent picker (asks which computer first), decision sheet all keyed by host + pane; "Pair a Mac" adds, "This iPhone" unpairs one host. Acceptance on the owner's two machines: both on the home under their own headers, a waiting agent on either surfaces on top, open/answer/create on each, revoking on one removes only that group. **The second host is the owner's ubuntu box — a clean slate (uninstalled 2026-09-01); pairing it again is the first step of the live pass (and also #48's remaining verification: agent cards + create-agent on Linux).** Phase E push identity will need the host in the payload — note, do not build.

**After #50:** #25 + #61 + #57 (diff glance → files-mentioned → project files, one read-only file endpoint), #58 dev-server preview, #59 worktrees. #54 P3 brand moments (icon, launch screen, App Store shots) are unblocked — bundle ID `com.farfield.tavi`, display name Tavi, acronym *Terminal Agent Vantage and Intervention* for the About screen/README, never the display name. #37 App Store epic gates any submission.

**Publishing rule (owner + agent, 2026-09-01):** the agent bumps `apps/host/package.json` + `VERSION` only when it says a release is worth publishing; the owner runs `cd apps/host && npm publish` in Terminal.app (2FA; the auth URL is masked under Claude Code). npm versions are immutable and propagate in 1–2 min. Paired hosts self-update within a day (`npx tavi-host update` now). Publish sparingly — every publish restarts every paired host.

**Open owner decisions:** whether phones should stop accepting the shared host token; a hosted relay as an opt-in for people who bounce off Tailscale (product call — `docs/PRODUCT.md` principle 2 says direct only; decide after testers); GitHub Actions publish job so releases stop needing the owner's terminal.

## Live state

- **Product:** Tavi by Farfield (Terminal Agent Vantage and Intervention). Repo `parvezrob/tavi`, checkout `~/Projects/tavi`. Host package `tavi-host` 0.1.9 on npm (Apache-2.0; everything else © Farfield). README quick start = `npx tavi-host pair`; the rest of the CLI: `doctor`, `update`, `devices [revoke]`, `install-service`/`uninstall-service`, `install-claude-hooks`, `uninstall`.
- **Owner Mac:** host runs from the checkout as launchd `com.farfield.tavi.host` (deploy: `npm run build && npm run service:install`, then `/api/health`); herdr 0.8.2 under `brew services start herdr` (headless; no tmux anywhere); Claude hooks installed. Phone runs `44216c5` as `com.farfield.tavi`, paired to the Mac (device `35348beb105b`). Tailscale Serve → :8787. Checkout hosts never self-update (by design).
- **Owner ubuntu:** clean slate — `tavi uninstall`ed 2026-09-01 after a verified pair. Node 24, Tailscale signed in (user is now a Tailscale operator), herdr 0.8.2 present. Next pair is a true first run.
- **Phone holds one host until #50** — pairing another replaces it.
- **Host ↔ herdr:** gate is protocol ≥ 17 + `agent.list` shape (`docs/HERDR_INTEGRATION.md`); verified on 17 (0.7.5) and 20 (0.8.2). `agent.read` sources `recent`/`visible`; digit keys select-and-confirm in Claude dialogs; `shift+tab` cycles modes.
- **Self-update / runtime:** `docs/DEVELOPMENT.md` "Self-update" (layout, launcher rollback, `TAVI_AUTO_UPDATE=off`, `TAVI_UPDATE_REGISTRY`, the fake-registry e2e recipe).
- **Needs-you fidelity (#22):** Claude hooks force `blocked · claude-hook` via `AttentionOverlay` until a resolution hook; #60 reconciler clears it when no dialog is on screen; phone adds 5 s hysteresis + stale banner. Hooks apply to **new** Claude sessions only.
- Prompt delivery: launch-pending retry, typing fallback via `send_keys`, post-prompt Enter nudge. Project roots from `TAVI_ROOTS` (default: existing of `~/Code`, `~/Projects`, `~/Developer`, `~/Documents`) — picker list and creation guardrail; no roots ⇒ every create needs confirmation.
- Live UI tests: export `TEST_RUNNER_TAVI_DEV_HOST/TOKEN` (token via `npm run -s token` in apps/host); they create disposable agents via `knownProjectPath` + `allowOutsideRoots` and clean up; check `xcresulttool` for skipped vs passed. Verification rule: for anything a person sees, look (screenshot / exact strings) — green suites have missed visible breakage three times.
- Open issues: #25, #27–#29 (parked), #37 epic, #39 test seam, #44 (owner decision), #47 (acceptance timing only), #48 (Linux cards/create + defaults), #50 next, #52 polish, #54 P3, #57–#59, #61.
- Security hygiene #31–#36 shipped; App Store readiness milestone + #37 gate any submission; `codebase-scan.html` is an audit input, never the tracker.
