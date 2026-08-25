# Current session

> Every agent starts here. This file holds the live state of the project *right now* and the next piece of work. Update it before ending a session (or at any significant milestone); move the previous state into [`handoffs.md`](./handoffs.md). Keep it short — details belong in the linked docs.

**Last updated:** 2026-08-26

## Next work

**Issue #24 — project picker when creating a new agent.** No more agents born in `~`. Show recent project roots from the host; require a folder tap; the host rejects create outside configured roots unless "custom" with an extra confirm. Ties to #12/#19 in the App Store epic.

Then, in order: #26 (project-grouped home + tmux card removal), #25 (diff glance), ROADMAP Phase C item 4 (terminal ergonomics, issue #10), then the founder-dogfood exit gate.

**#23 shipped 2026-08-25** (`2385f05` host, `0405d05` iOS): approve/deny a waiting permission from the Needs-you card. Two-layer trust gate — outer: at least one authority (hook overlay OR herdr blocked) flags a wait; inner (`decideAgent`): the pane is re-read and a real dialog must still parse before any key is sent, so a stale card can never answer. approve=Enter, deny=Esc. `dialog.ts` parser (numbered options + "Enter to confirm · Esc to cancel" footer). Phone: `PermissionDecisionSheet` shows the real choices + Open terminal. Live-verified end-to-end via `testApproveWaitingPermissionFromNeedsYouCard`. Note: the double-authority gate from the original design note was relaxed to "either authority" because some dialogs (trust-folder prompt) are herdr-blocked but emit no PermissionRequest hook; the inner pane re-read is the real safety.

## Live state

- Phases A and B complete; Phase C items 1–3 shipped and live-verified (Sessions home, terminal identity + Jump-to, composer + key-cap quick-key row with compose/live mode toggle). See ROADMAP.
- **Needs-you fidelity (#22) shipped:** Claude Code hooks (`npm run hooks:install`, installed on the owner Mac) force `blocked · claude-hook` via the host's `AttentionOverlay` until a resolution hook fires; phone adds a 5 s de-escalation hysteresis (`AgentStatusSmoother`) and keeps last-known state through stream drops with a stale banner. Hooks apply to **new** Claude sessions only. Contract details: `docs/DEVELOPMENT.md`.
- Prompt delivery hardened: launch-pending retry, typing fallback via `send_keys` (spaces travel as "Space", idle-pane guard), post-prompt Enter nudge. Herdr quirk: owner's sessions run in manual mode — phone prompts can still occasionally sit unsubmitted.
- Feature decisions 2026-08-26 recorded in `docs/ROADMAP.md` (adopted #23–#29, rejected list). Multi-host = Phase D item 3; push notifications = Phase E item 1.
- Host runs the latest launchd build; phone has the latest app build. Deploy loop: `docs/DEVELOPMENT.md`. Watch for #21 (first `service:install` attempt often fails; retry succeeds — verify with `/api/health` after deploys, a half-installed service serves 502s via Tailscale).
- Open issues: #8 (old PWA, unrelated), #10 (scroll feel), #21 (installer retry), #23–#29 (adopted work).
- **App Store readiness (2026-08):** milestone “App Store review readiness” + epic #37 gate any Apple submission. `codebase-scan.html` (#30) is a second-agent audit whose claims were re-verified against the code — input only, never the tracker.
- **Security hygiene #31–#36 shipped and closed** (`0a02cf9` host, `b32b9c4` iOS): token in Keychain with one-time migration off AppStorage + truthful storage copy on both connect screens; Claude hook runs `claude-hook-relay.js` so the token never hits argv (reinstalled on the owner Mac); dev env seeding is DEBUG-only; CORS headers deleted; `~/.mocha` forced 0700/0600; AgentDirectory on an ephemeral URLSession. **The phone still runs the pre-Keychain build — install the latest app build before further dogfood.**
- Live UI tests: `testNeedsYouSurvivesVisitingTheBlockedAgent` and `testAgentTerminalShowsIdentityAndJumpSheet` create their own disposable agents and clean up; they need `TEST_RUNNER_MOCHA_DEV_HOST/TOKEN` exported and can skip honestly if the agent never blocks — check `xcresulttool` for skipped vs passed.
