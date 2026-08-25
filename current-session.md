# Current session

> Every agent starts here. This file holds the live state of the project *right now* and the next piece of work. Update it before ending a session (or at any significant milestone); move the previous state into [`handoffs.md`](./handoffs.md). Keep it short — details belong in the linked docs.

**Last updated:** 2026-08-25

## Next work

**Issue #24 — project picker when creating a new agent.** No more agents born in `~`. Show recent project roots from the host; require a folder tap; the host rejects create outside configured roots unless "custom" with an extra confirm. Ties to #12/#19 in the App Store epic. Note: `createTab` already accepts a `cwd` (used by the #23 UI test and disposable-agent probes) and `POST /api/herdr/tabs` validates it as an absolute path — the picker mostly needs the roots list surfaced on the phone + a required selection.

Then, in order: #26 (project-grouped home + tmux card removal), #25 (diff glance), ROADMAP Phase C item 4 (terminal ergonomics, issue #10), then the founder-dogfood exit gate.

**#23 shipped and closed 2026-08-25** (`2385f05` → `3998b89`): answer a waiting permission straight from the Needs-you card, no terminal.
- `dialog.ts` detects a prompt by **structure** (≥2 numbered options with the `❯`-highlighted arrow), not footer wording — footers vary across Claude's project-decision prompts (trust folder, Bash approval, MCP, plan…); a known footer is only a secondary acceptor. Verified live that footer-matching missed real Bash dialogs.
- Dialog read uses herdr `source: "visible"` (current viewport), not `"recent"` — `recent` scrolled a static dialog out on status-line repaints and caused false "Already resolved". Fixed.
- **Per-option picking:** the sheet renders every option as a tappable button and sends that digit (Claude treats a number key as select-and-confirm — verified live). `decideAgent` re-reads the visible dialog and confirms the option index still exists before sending, so a stale option can't land on another prompt. approve=Enter, deny=Esc still exist in the host API. "always allow"/"don't ask" options are flagged "Grants standing access" (shield) in the UI.
- Two-layer trust gate: outer = at least one authority (hook overlay OR herdr blocked) flags a wait; inner = the visible re-read must parse a real dialog before any key fires. The original "hook AND herdr" note was relaxed to "either" because some dialogs (trust-folder) are herdr-blocked but emit no PermissionRequest hook; the re-read is the real safety.
- Live UI test: `testAnswerWaitingPermissionFromNeedsYouCard` (taps a specific numbered option, asserts the host cleared the dialog). Host suite 78/78.

## Live state

- Phases A and B complete; Phase C items 1–3 shipped and live-verified (Sessions home, terminal identity + Jump-to, composer + key-cap quick-key row with compose/live mode toggle). See ROADMAP.
- **Needs-you fidelity (#22) shipped:** Claude Code hooks (`npm run hooks:install`, installed on the owner Mac) force `blocked · claude-hook` via the host's `AttentionOverlay` until a resolution hook fires; phone adds a 5 s de-escalation hysteresis (`AgentStatusSmoother`) and keeps last-known state through stream drops with a stale banner. Hooks apply to **new** Claude sessions only. Contract details: `docs/DEVELOPMENT.md`.
- Prompt delivery hardened: launch-pending retry, typing fallback via `send_keys` (spaces travel as "Space", idle-pane guard), post-prompt Enter nudge. Herdr quirk: owner's sessions run in manual mode — phone prompts can still occasionally sit unsubmitted.
- Feature decisions 2026-08-26 recorded in `docs/ROADMAP.md` (adopted #23–#29, rejected list). Multi-host = Phase D item 3; push notifications = Phase E item 1.
- Host runs the latest launchd build; phone has the latest app build. Deploy loop: `docs/DEVELOPMENT.md`. Watch for #21 (first `service:install` attempt often fails; retry succeeds — verify with `/api/health` after deploys, a half-installed service serves 502s via Tailscale).
- Open issues: #8 (old PWA, unrelated), #10 (scroll feel), #21 (installer retry), #23–#29 (adopted work).
- **App Store readiness (2026-08):** milestone “App Store review readiness” + epic #37 gate any Apple submission. `codebase-scan.html` (#30) is a second-agent audit whose claims were re-verified against the code — input only, never the tracker.
- **Security hygiene #31–#36 shipped and closed** (`0a02cf9` host, `b32b9c4` iOS): token in Keychain with one-time migration off AppStorage + truthful storage copy on both connect screens; Claude hook runs `claude-hook-relay.js` so the token never hits argv (reinstalled on the owner Mac); dev env seeding is DEBUG-only; CORS headers deleted; `~/.mocha` forced 0700/0600; AgentDirectory on an ephemeral URLSession.
- Host runs the latest launchd build; **phone has the latest #23 build installed** (Keychain + per-option decision sheet).
- herdr `agent.read` sources: `recent` (rolling recent output) and `visible` (current viewport). Use `visible` for anything that must reflect the live screen (e.g. dialog detection). Digit keys are select-and-confirm in Claude dialogs; `shift+tab` is the accepted spelling to cycle modes (`S-Tab`/`BTab` are rejected).
- Live UI tests: `testAnswerWaitingPermissionFromNeedsYouCard`, `testNeedsYouSurvivesVisitingTheBlockedAgent`, `testAgentTerminalShowsIdentityAndJumpSheet` create their own disposable agents (some in a fresh `/private/tmp` cwd to force a trust dialog) and clean up; need `TEST_RUNNER_MOCHA_DEV_HOST/TOKEN` exported, skip honestly if the agent never blocks — check `xcresulttool` for skipped vs passed.
