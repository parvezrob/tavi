# Current session

> Every agent starts here. This file holds the live state of the project *right now* and the next piece of work. Update it before ending a session (or at any significant milestone); move the previous state into [`handoffs.md`](./handoffs.md). Keep it short — details belong in the linked docs.

**Last updated:** 2026-08-31

## Next work

**#24 needs its live pass before it can close.** Code is committed (`ec8e14a`) and every local gate is green, but the acceptance criterion — "create Claude in a chosen repo from the phone; picker remembers recent choices" — is unverified on a device. It requires deploying the host **and** installing the new app build **together**: `cwd` is now required on `POST /api/herdr/tabs`, so the phone build currently on the device cannot create agents against the new host. Deploy loop in `docs/DEVELOPMENT.md`; watch #21 (retry `service:install`, confirm `/api/health`).

Then, in order: #26 (project-grouped home + tmux card removal), #25 (diff glance), ROADMAP Phase C item 4 (terminal ergonomics, issue #10), then the founder-dogfood exit gate.

**#24 shipped 2026-08-31** (`ec8e14a`): agents are born where you choose, never in `~`.
- `POST /api/herdr/tabs` **requires** `cwd` (absolute, existing, a directory). Outside the configured roots it returns `400 {outsideRoots: true}`; only a request carrying `allowOutsideRoots: true` proceeds, and the phone sends that only after an explicit confirm alert. This is a **breaking protocol change** — host and app must deploy together.
- `GET /api/projects` → `{recent, workspaces, roots}`. `recent` merges live agent cwds with a persisted MRU (`~/.mocha/projects.json`, versioned, 0600, fsync + atomic swap, last 12); folders that no longer exist are dropped, not offered.
- **Path comparison normalizes explicitly** (`path.resolve` → NFC → lowercase). macOS `realpath` does *not* canonicalize case or Unicode — verified directly. Without this, a root spelled in another case rejects every folder under it, and one folder eats two MRU slots.
- The roots rule has **one owner: the host.** The phone marks outside-roots folders up front (`withinRoots`) as a courtesy, but the confirmation is driven by the host's actual 400, so the two can never disagree.
- `NewAgentSheet` (agent kind + required folder, Recent/Projects, search, custom path) replaces the old Claude/Codex confirmation dialog. `ProjectPicker` holds the pure filter/de-dup logic, unit tested.
- Verified: host check/build clean, 94/94; iOS build + test build + MochaTests pass on iPhone 17 Pro (26.5).

## Live state

- Phases A and B complete; Phase C items 1–3 shipped and live-verified (Sessions home, terminal identity + Jump-to, composer + key-cap quick-key row with compose/live mode toggle). See ROADMAP.
- **Needs-you fidelity (#22) shipped:** Claude Code hooks (`npm run hooks:install`, installed on the owner Mac) force `blocked · claude-hook` via the host's `AttentionOverlay` until a resolution hook fires; phone adds a 5 s de-escalation hysteresis (`AgentStatusSmoother`) and keeps last-known state through stream drops with a stale banner. Hooks apply to **new** Claude sessions only. Contract details: `docs/DEVELOPMENT.md`.
- Prompt delivery hardened: launch-pending retry, typing fallback via `send_keys` (spaces travel as "Space", idle-pane guard), post-prompt Enter nudge. Herdr quirk: owner's sessions run in manual mode — phone prompts can still occasionally sit unsubmitted.
- Feature decisions 2026-08-26 recorded in `docs/ROADMAP.md` (adopted #23–#29, rejected list). Multi-host = Phase D item 3; push notifications = Phase E item 1.
- Deploy loop: `docs/DEVELOPMENT.md`. Watch for #21 (first `service:install` attempt often fails; retry succeeds — verify with `/api/health` after deploys, a half-installed service serves 502s via Tailscale).
- Open issues: #8 (old PWA, unrelated), #10 (scroll feel), #21 (installer retry), #24–#29 (adopted work), #38 (`POST /api/sessions` bypasses the roots guardrail), #39 (no test seam for `AgentDirectory`'s HTTP calls), #40 (`herdr-events` intermittent failure — was prose in DEVELOPMENT.md, now tracked).
- **App Store readiness (2026-08):** milestone “App Store review readiness” + epic #37 gate any Apple submission. `codebase-scan.html` (#30) is a second-agent audit whose claims were re-verified against the code — input only, never the tracker.
- **Security hygiene #31–#36 shipped and closed** (`0a02cf9` host, `b32b9c4` iOS): token in Keychain with one-time migration off AppStorage + truthful storage copy on both connect screens; Claude hook runs `claude-hook-relay.js` so the token never hits argv (reinstalled on the owner Mac); dev env seeding is DEBUG-only; CORS headers deleted; `~/.mocha` forced 0700/0600; AgentDirectory on an ephemeral URLSession.
- **Host and phone are both one build behind `main` as of #24** — neither has been redeployed since `ec8e14a`, and they must be updated together (required `cwd` is breaking). Before that: host on the latest launchd build, phone on the #23 build (Keychain + per-option decision sheet).
- Project roots come from `MOCHA_ROOTS`, defaulting to whichever of `~/Code`, `~/Projects`, `~/Developer`, `~/Documents` exist. They are both the picker's browsable list and the guardrail on where a phone-created agent may start. A host with no roots makes every create require confirmation — deny-by-default, and the picker says so.
- herdr `agent.read` sources: `recent` (rolling recent output) and `visible` (current viewport). Use `visible` for anything that must reflect the live screen (e.g. dialog detection). Digit keys are select-and-confirm in Claude dialogs; `shift+tab` is the accepted spelling to cycle modes (`S-Tab`/`BTab` are rejected).
- Live UI tests create their agents through `knownProjectPath` (reads the host's own catalog rather than hard-coding a machine layout) and pass `allowOutsideRoots`, since they only need a real folder. Tests: `testAnswerWaitingPermissionFromNeedsYouCard`, `testNeedsYouSurvivesVisitingTheBlockedAgent`, `testAgentTerminalShowsIdentityAndJumpSheet` create their own disposable agents (some in a fresh `/private/tmp` cwd to force a trust dialog) and clean up; need `TEST_RUNNER_MOCHA_DEV_HOST/TOKEN` exported, skip honestly if the agent never blocks — check `xcresulttool` for skipped vs passed.
