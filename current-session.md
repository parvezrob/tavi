# Current session

> Every agent starts here. This file holds the live state of the project *right now* and the next piece of work. Update it before ending a session (or at any significant milestone); move the previous state into [`handoffs.md`](./handoffs.md). Keep it short — details belong in the linked docs.

**Last updated:** 2026-08-26

## Next work

**Issue #23 — approve/deny a waiting permission straight from the Needs-you card.** The core intervention loop without entering the terminal. Design notes:

- Trust gate: act only when the hook overlay (`authority: "claude-hook"`) **and** herdr agree a dialog is up; a stale card must never fire keys at a pane whose dialog is gone. Read the pane (`agent.read`) immediately before sending to confirm the dialog is still rendered.
- Delivery: `agent.send_keys` to the exact pane (approve = Enter on the highlighted option; deny = Esc or the numbered option — read the dialog text to present the real choices).
- Surface: options on the Needs-you card (or a Q0-style detail sheet per `docs/V1_SCREEN_AND_NAVIGATION_MAP.md`), always with "Open terminal" as the escape hatch.
- Acceptance: from cold app open, median under 5 s to an approved permission.

Then, in order: #24 (project picker for new agents), #26 (project-grouped home + tmux card removal), #25 (diff glance), ROADMAP Phase C item 4 (terminal ergonomics, issue #10), then the founder-dogfood exit gate.

## Live state

- Phases A and B complete; Phase C items 1–3 shipped and live-verified (Sessions home, terminal identity + Jump-to, composer + key-cap quick-key row with compose/live mode toggle). See ROADMAP.
- **Needs-you fidelity (#22) shipped:** Claude Code hooks (`npm run hooks:install`, installed on the owner Mac) force `blocked · claude-hook` via the host's `AttentionOverlay` until a resolution hook fires; phone adds a 5 s de-escalation hysteresis (`AgentStatusSmoother`) and keeps last-known state through stream drops with a stale banner. Hooks apply to **new** Claude sessions only. Contract details: `docs/DEVELOPMENT.md`.
- Prompt delivery hardened: launch-pending retry, typing fallback via `send_keys` (spaces travel as "Space", idle-pane guard), post-prompt Enter nudge. Herdr quirk: owner's sessions run in manual mode — phone prompts can still occasionally sit unsubmitted.
- Feature decisions 2026-08-26 recorded in `docs/ROADMAP.md` (adopted #23–#29, rejected list). Multi-host = Phase D item 3; push notifications = Phase E item 1.
- Host runs the latest launchd build; phone has the latest app build. Deploy loop: `docs/DEVELOPMENT.md`. Watch for #21 (first `service:install` attempt often fails; retry succeeds — verify with `/api/health` after deploys, a half-installed service serves 502s via Tailscale).
- Open issues: #8 (old PWA, unrelated), #10 (scroll feel), #21 (installer retry), #23–#29 (adopted work).
- Live UI tests: `testNeedsYouSurvivesVisitingTheBlockedAgent` and `testAgentTerminalShowsIdentityAndJumpSheet` create their own disposable agents and clean up; they need `TEST_RUNNER_MOCHA_DEV_HOST/TOKEN` exported and can skip honestly if the agent never blocks — check `xcresulttool` for skipped vs passed.
