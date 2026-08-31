# Session handoffs

> Append-only log of completed work sessions, newest first. Each entry is what the *next* agent needs to know about that session: what shipped, what was learned, what was left open. The live starting point is always [`current-session.md`](./current-session.md); prune entries older than a few sessions — git history keeps everything.

## 2026-09-01 (small hours) — #54 design pass P1+P2

**Shipped:** the premium-not-flashy pass. Audit first (nine live screens, reusable `MochaScreenshotAudit` harness, "Mocha Design Audit" artifact), then P1 (graphite ramp + one amber accent + cream tint in `MochaTheme`, `ad01c76`) and P2 (every screen, `fc6eee8`), each verified by two Opus passes with all substantive findings fixed pre-commit, each recaptured by the harness after. Owner steered mid-pass: warm/cream rejected (too Anthropic), Liquid Glass chrome adopted for the terminal, ended-sessions get a composed final state, connection state lives in the dot beside the pane name.

**Learned:** put status banners in overlays, never in the layout — an in-layout banner made the terminal's height connection-dependent and double-resized the Mac's pty every reconnect flap. Gate keyboard chrome on `keyboardWillShow`, not mode flags — the Ghostty surface raises the keyboard from UIKit outside SwiftUI's state. One accent means the *tint* can't be the accent: amber as global tint made every Done button the attention color. `.plain` buttons hit-test only their glyphs — `contentShape` or a background restores the target. A `List` is lazy: a row moved to the bottom doesn't exist for XCUITest until scrolled to.

**Left open:** #54 P3 (icon/launch/App Store, gated on the name); #52's honest disambiguator; the banner-tap behavior call; owner's hands-on pinch check from #51.

## 2026-08-31 (later night) — #51 Settings: font size + pinch, Face ID lock

**Shipped:** #51 — Settings (Terminal / Security / Privacy per the issue-comment skeleton), one persisted terminal font size driven by both a slider and pinch, a measured grid readout from a real Ghostty preview surface, Face ID app lock (default off) behind its own UIWindow cover, "This iPhone" relocated under Security. Live-verified: the Mac's herdr pane follows the phone's font-size grid (8 pt → 62×42 → `viewport_rows: 42`). Full suite green; phone build installed.

**Learned:** an app's `UserDefaults` live in the app container — `simctl spawn defaults` writes a different domain, and cfprefsd's cache beats direct plist edits, hence the `MOCHA_DEV_FONT_SIZE` seed. Ghostty's `set_font_size` binding action re-flows synchronously (vendored `Surface.setFontSize` assigns the cell size before returning), so no delayed re-read is needed. A ZStack privacy cover is a lie twice over: sheets present *above* it and VoiceOver walks straight through it — cover with a UIWindow at alert level and hide content from accessibility. Lock on scene-*inactive*, not background, or the app-switcher snapshot shows the terminal. `find … -name Mocha.app | head -1` picked a stale Release product over the fresh Debug one — name the configuration path explicitly. A slider's `accessibilityValue` read back through XCUITest asserts persistence and the VoiceOver criterion in one line.

**Left open:** owner's hands-on pinch check on the physical phone at both extremes under a full-screen TUI; Face ID default stays an open owner decision; #21 root cause is next.

## 2026-08-31 (late night) — #53 tmux lane deleted

**Shipped:** #53 — tmux removed from host, app, tests, and docs; herdr is the only backend. Owner decision: delete rather than maintain a dormant fallback. Host deployed; old routes 404; all ported live UI tests green against the deployed cutover.

**Learned:** the terminal-bridge tests didn't care about tmux at all — they ported to a stub herdr by swapping the fixture (`terminalHerdr`/`fixtureHerdr`), evidence the bridge/backends seam was real. herdr's attach viewer freezes the frame while scrolled into history (like tmux copy-mode) — flick-until-live-again is the honest streaming probe. #21's install-service first-attempt crash reproduced on this deploy; still needs a root cause.

**Left open:** #47 owns running herdr as a service (it still needs a PTY; the owner's Mac starts it inside a detached tmux session as an ops convenience). #21 root cause. #52 home polish.

## 2026-08-31 (night) — #26 project-grouped home

**Shipped:** #26 — home is needs-you (flat) then computer → project → agents; tmux card retired to the DEBUG Host menu; `HomeGrouping` model built host-aware for #50. Verified by screenshot on the simulator with agents in three folders, by the live UI test, and installed on the phone.

**Learned:** `Text` only inflects `^[…](inflect: true)` from a literal `LocalizedStringKey` — a computed `String` renders the markup verbatim (seen on screen, not by tests). Herdr's default tab title is the *product name* ("Claude Code"), not the kind, so "title repeats the agent" checks must compare against `displayName` too; a shell's title is its prompt. `URL(fileURLWithPath: "")` resolves against the process cwd — guard empty paths before taking `lastPathComponent`. XCUITest: async calls inside `XCTUnwrap`/`XCTAssert` autoclosures don't compile — hoist them. The two-verifier pass found a latent duplicate-id bug in `group()` that the pre-filtering caller hid; keep invariants inside the function that owns them.

**Left open:** #52 (home polish: identical same-kind rows in one folder, density of single-agent projects, an action on the empty home, UI coverage of the in-group running card). Phase D still owes the decision to restore or delete the tmux lane.

## 2026-08-31 (evening) — #44 sizing, #45 QR pairing, #46 device credentials

**Shipped:** #44 step 1 (detach → viewer rect); #45 pairing end to end; #46 host side (per-device credentials, list/revoke CLI + API, live-cut on revoke, self-unpair endpoint).

**Learned:** two bugs the whole green suite could not see surfaced only on the real phone: `mocha pair` printed no QR (I had piped its output through grep when "verifying"), and the fingerprint's spaces travelled as `+` (both sides' tests had hand-typed `%20`). Rule: for anything a person looks at, verify by looking — screenshot or the actual string the other side produces. herdr pane size is last-writer-wins (see current-session). Free-account provisioning profiles expire after 7 days → "App no longer available" / "Untrusted developer" (documented in DEVELOPMENT.md). VisionKit's `.qr` symbology needs `import Vision` as well as `VisionKit`. UI-test teardown closures must call static helpers (non-Sendable `self`).

**Left open:** #46 phone-side manage-access; #44 steps 2–3; the shared host token still authorizes phones (kept so the simulator/UI tests and the owner's current phone keep working — decide when to retire it).

## 2026-08-31 (later) — #41 agent kinds, #42 empty terminal

**Shipped:** #42 — Terminal in the picker via `pane.report_agent` (`shell/idle`, `source: mocha`); opens through the normal agent terminal. #41 (`6bb38af`) — picker offers every herdr kind (21) via a one-row menu; host serves `agents` on `GET /api/projects` with login-shell installed detection and refuses uninstalled kinds by name.

**Learned (#44):** herdr pane size is last-writer-wins — an external attach sets the pane's terminal size and herdr never restores it; its viewer just shows a fixed rect onto whatever the terminal is. `session.snapshot` exposes that rect per pane. `pane get` has no size fields; `tput cols`×`tput lines` via `pane send-text` + `pane read` is the way to measure. Also: herdr `agent.start` with an uninstalled kind returns a tab whose launch already died (`agent: ''`, `unknown`, blank) — the host must gate. Login shell (`$SHELL -lc`) is the honest PATH authority under launchd. 21 inline rows broke the picker's layout again (same trap as "Another folder" earlier) — long lists in this sheet must collapse. Empty terminal in the herdr lane is feasible via `pane report-agent` (see current-session.md).

## 2026-08-31 — #24 project picker, host-enforced project roots

**Shipped (commit `ec8e14a`):** #24 — no more agents born in `~`. `cwd` is now **required** on `POST /api/herdr/tabs`; a location outside the configured roots is refused with `400 {outsideRoots: true}` unless the request confirms with `allowOutsideRoots`. New `GET /api/projects` serves the picker (live agent cwds merged with a persisted MRU, plus the root scan and the roots). `NewAgentSheet` replaces the Claude/Codex confirmation dialog with agent kind + a required folder choice.

**Learned:**
- **macOS `realpath` does not canonicalize case or Unicode** — it echoes whatever spelling you hand it (verified directly). Path comparison therefore normalizes explicitly (`path.resolve` → NFC → lowercase). Without it, `MOCHA_ROOTS` spelled in a different case would have made *every* create demand the outside-roots confirmation, and one folder would occupy two MRU slots.
- `path.resolve("")` is the process's own cwd, so `MOCHA_ROOTS` must drop blank entries *before* resolving — a trailing comma silently widened the guardrail.
- The roots check is a guardrail, not a security boundary: `POST /api/sessions` still accepts an arbitrary `cwd` plus an arbitrary command, and the token is shell access either way. Recorded as #38 rather than quietly expanded into #24.
- **Driving the real UI found what neither the verifiers nor the full green suite could:** "Another folder" was rendered below the project list and under iOS 26's floating search field — reachable only by scrolling past every project, and occluded on arrival. Unit tests cannot see an unreachable control. It now sits under the agent picker.
- Two Opus verifier passes (host and iOS) found real defects the local gates could not: silent `catch {}` around every history write, an unversioned persisted schema, a test writing into the developer's real `$TMPDIR`, a self-contradicting unit-test assertion, and a client that discarded the very `withinRoots` field the protocol ships to prevent a surprise confirmation. Worth repeating on consequential changes.

**Left open:** #24 is closed — verified live in the simulator against the deployed host (`425ea19`). The **phone still needs the new app build installed**; the #23 build on the device gets a 400 on create because `cwd` is now required. Then #26, #25, #10, dogfood gate. Follow-ups filed: #38, #39 (no test seam for `AgentDirectory`'s HTTP calls), #40 (`herdr-events` flake, previously only prose in DEVELOPMENT.md).

## 2026-08-25 — App Store readiness milestone, security hygiene, #23 approve/deny

**Shipped (commits `8867740` → `3998b89`):**
- App Store readiness gate: milestone "App Store review readiness" + epic #37 (the master checklist before any Apple submission). `codebase-scan.html` (#30, a Cursor-authored audit) treated as second-agent *input*, re-verified against the code — never the tracker.
- Security hygiene #31–#36 (all closed): pairing token moved to the iOS Keychain (this-device-only) with a one-time migration off UserDefaults and truthful storage copy on both connect screens; Claude hook rewritten as `claude-hook-relay.js` so the token never appears in argv; dev-env credential seeding gated to DEBUG; browser CORS headers removed; `~/.mocha` log/dir forced to 0700/0600; `AgentDirectory` moved to an ephemeral (no-cache) URLSession. Verified live (Keychain migration on-device; hook reinstall on the owner Mac preserved foreign orca/moshi entries).
- #23 approve/deny from the Needs-you card (closed): `PermissionDecisionSheet` answers a waiting permission without the terminal. Dialog detection is **structural** (numbered options + `❯` arrow), not footer-string based; reads the **visible viewport** not recent output; supports **per-option picking** (each choice a button that sends its digit), with "always allow" options flagged as granting standing access. Two-layer trust gate (an authority flags the wait; a visible re-read must still parse a real dialog before any key fires). Live UI test `testAnswerWaitingPermissionFromNeedsYouCard`.

**Learned:** herdr `agent.read` has `recent` (rolling output) vs `visible` (viewport) — use `visible` for live-screen truth; Claude dialog footers differ by prompt type, so detect by the `❯`-highlighted numbered list; number keys are select-and-confirm in Claude dialogs; `shift+tab` is the accepted send_keys spelling to cycle modes. #21 installer flake hit repeatedly this session — `service:install` first attempt fails, a direct `node dist/index.js install-service` retry succeeds; always confirm `/api/health`.

**Left open:** #24 next (project picker — `createTab` already takes a validated `cwd`, mostly needs the roots list on the phone + required selection), then #26/#25/#10, dogfood gate. The App Store epic (#37) items — demo mode, privacy packaging, icon, pairing, per-device revoke — remain for when a TestFlight push is actually targeted (also needs the paid Apple account).

## 2026-08-26 — Phase C items 1–3, needs-you fidelity, feature decisions

**Shipped (commits `125fe22` → `2b1a827`):**
- Sessions home (#18): dark-committed MochaTheme visual system, Needs-you/Active/Recent cards with sanitized previews, freshness, project directory rows; honest empty/degraded/loading/stale states.
- Terminal identity + Jump-to (#19): `GET /api/herdr/tree`, live identity header, hierarchy sheet with Current badge.
- Composer + quick keys (#20): deliberate-send composer (structured prompt for agents, bracketed paste + explicit return for terminals), key-cap control bar, Ctrl latch, compose/live single-typing-target mode toggle. `DELETE /api/herdr/tabs/{tabId}` added.
- Needs-you fidelity (#22): Claude Code hook overlay on the host (`AttentionOverlay` + `AttentiveAgentEvents`, `POST /api/hooks/claude`, `npm run hooks:install`); phone-side `AgentStatusSmoother` hysteresis and stale-state retention. Live-verified full lifecycle: permission ask → `blocked·claude-hook` in seconds, persists unanswered, clears on approval.
- Prompt delivery: launch-pending retry, typing fallback ("Space" key mapping, idle guard), Enter nudge — all against live-observed herdr behaviors, recorded in `docs/DEVELOPMENT.md`.
- Feature decisions from competitor survey (t3code source-read, Happy, Omnara): adopted #23–#29 + rejected list, recorded in ROADMAP.

**Learned:** herdr `agent_status` flaps and can mis-detect around dialogs (hence hooks); `agent.prompt` needs launch-pending handling; LazyVStack can serve a stale card when a row changes sections (home is a plain VStack with status-keyed identity now); UI tests must reset persisted AppStorage (`MOCHA_DEV_RESET`); live tests must target their own disposable agents, never `firstMatch` (an early test prompted an owner session by accident — twice).

**Left open:** #23 next (approve/deny from the card — design notes in current-session.md), then #24/#26/#25, ergonomics (#10), dogfood gate. #21 installer flake persists — always verify `/api/health` after deploys.

## 2026-08-25 — Phases A and B, complete

**Shipped (commits `b545fe4` → `73ce984`):**
- Phase A (issues #12, #13, #14, gates #4/#5): launchd host service with auto-restart; network-path-aware sub-second reconnect (NWPathMonitor, honest `waitingForNetwork` state, 3 s connect deadline, 250 ms first retry); `mocha.v2` transport — persistent pty attachments, binary output frames, exact-offset resume (verified 0 lost / 0 duplicated bytes across a hard mid-stream drop). All lifecycle gates passed on the physical iPhone 12 Pro.
- Phase B (issues #15, #16, #17): Herdr agents attachable at `/api/agents/{pane}/terminal`; `/api/events` WS pushes full agent snapshots sub-second; bounded previews; one-shot `agent.prompt` (verified live — reply and status transitions within ~2 s); phone-created agent tabs (Claude/Codex) with unique-name + shell-boot-retry fixes; live Agents list + tap-to-pane on the phone. tmux fallback intact throughout.
- Post-gate fixes from owner field testing: agent-name collision, shell-not-ready race, orphan-tab cleanup, Herdr error text surfaced to the phone, detach size restore (Mac pane no longer stays phone-width after locking the phone).
- Knowledge moved into the repo: `docs/DEVELOPMENT.md`, `docs/HERDR_INTEGRATION.md`, transport v2 spec in `protocol/README.md`.

**Learned (recorded in the docs above):** Herdr per-pane status subscriptions with mandatory global `pane.agent_detected`; `agent.start` unique-name requirement; `result.read.text` shape; launchd needs an explicit UTF-8 LANG or tmux corrupts its field separator; `MOCHA_DEV_HOST` must be the Tailscale HTTPS URL; TEST_RUNNER_ vars must be exported; cwd drifts between shell calls — use absolute `cd`.

**Left open:** Phase C (next), issue #10 (scroll feel), issue #8 (unrelated PWA). Owner decisions of note: keep tmux as invisible backbone with Herdr as the featured brain; dev token flow acceptable until Phase D; "Empty tab" option removed from the phone until plain panes are listable.
