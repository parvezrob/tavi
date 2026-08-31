# Development and verification loop

Practical knowledge for building, deploying, and verifying Mocha end-to-end. Policy lives in [`DEVELOPMENT_PRINCIPLES.md`](./DEVELOPMENT_PRINCIPLES.md); this file is the how.

## Host

- The host runs as a launchd LaunchAgent `com.parvezrob.mocha.host` (KeepAlive auto-restart). Logs: `~/.mocha/host.log`.
- **Deploying host changes:** the service runs `dist/`, not watch mode. From `apps/host`: `npm run build && npm run service:install` (install boots the old instance out and kickstarts the new one). `npm run dev` remains available for iteration but is not how the phone connects.
- Reveal the pairing token: `npm run token` in `apps/host`.
- The launchd plist sets a UTF-8 `LANG` deliberately: without a locale, tmux sanitizes the `\x1f` list-format field separator to `_` and session parsing breaks.
- Host tests: `npm test` in `apps/host`. `herdr-events.test.ts` has a rare timing flake — rerun before trusting a failure.

## iOS

- Simulator verification loop (no taps needed):
  1. `xcodebuild -scheme Mocha -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
  2. Launch with the DEBUG bootstrap: `SIMCTL_CHILD_MOCHA_DEV_HOST=<https tailscale url> SIMCTL_CHILD_MOCHA_DEV_SESSION=<tmux session> SIMCTL_CHILD_MOCHA_DEV_TOKEN=$(npm run -s token) SIMCTL_CHILD_MOCHA_DEV_AUTO_OPEN_TERMINAL=1 xcrun simctl launch <sim udid> com.parvezrob.mocha`
  3. Inject from outside via `tmux -L mocha send-keys`, verify with `xcrun simctl io <udid> screenshot` and `log show --info --predicate 'subsystem == "com.parvezrob.mocha"'`.
- **`MOCHA_DEV_HOST` must be the Tailscale Serve HTTPS URL.** The app enforces HTTPS + `.ts.net`; `http://127.0.0.1` fails as "Connection failed" and makes every live UI test fail with a misleading "output did not reach the screen".
- Live UI tests need `TEST_RUNNER_MOCHA_DEV_HOST/SESSION/TOKEN` **exported** (CLI assignments to xcodebuild do not reach the runner). `testTouchScrollLeavesStreamingHealthy` needs an ambient output loop running in the target session; it generates none itself.
- UI-test failure details: `xcrun xcresulttool get test-results tests --path <latest .xcresult under DerivedData/.../Logs/Test>`.
- Physical device install: `xcrun devicectl device install app --device <udid> <DerivedData>/Build/Products/Debug-iphoneos/Mocha.app` — the phone must be unlocked and plugged in; "unavailable" resolves by unlocking and retrying.
- Device connection settings on the phone live behind the Host button. The host address is AppStorage `mocha.dev.host`; the token lives in the Keychain (`HostCredentialStore`, this-device-only, #31 — a pre-Keychain AppStorage token migrates and is deleted on first launch). Phase D replaces this with QR pairing + per-device credentials.
- Simulator gotcha: `simctl spawn <udid> defaults write com.parvezrob.mocha …` hits the *device-level* domain, which the app never reads. The app's real defaults are the plist under `simctl get_app_container <udid> com.parvezrob.mocha data` → `Library/Preferences/`.

## Claude Code hooks (needs-you fidelity, issue #22)

- Herdr's `agent_status` is screen detection and can lag or flap around permission dialogs. The host overlays durable facts from Claude Code's own hooks: `PermissionRequest`/`Notification` (permission message) force `blocked` with `authority: "claude-hook"` on the matching agent; `PostToolUse`, `Stop`, or `UserPromptSubmit` clear it (`SubagentStop` deliberately does not). Overlay entries expire after 60 min as a phantom-block backstop.
- Install into `~/.claude/settings.json` with `npm run hooks:install` (merges alongside existing hooks, writes a `.mocha-backup`, safe to re-run; it also replaces the pre-relay curl command). Hooks apply to **new** Claude sessions only. The command is `node dist/claude-hook-relay.js <port>` — the relay reads the token from `~/.mocha/config.json` at fire time and POSTs the hook stdin to `POST /api/hooks/claude`, so the token never appears in any process argv (issue #32). Re-run `hooks:install` after moving the repo (the settings entry carries an absolute path).
- Join key: the hook's `session_id` equals herdr's `agent_session.value` (`sessionRef` on the wire). Agents without a session ref are never overlaid.
- Verified live 2026-08-26: permission ask → `blocked · claude-hook` on `/api/agents` and the events feed within seconds, persists while unanswered, clears on approval via `PostToolUse`.

## tmux lane

- Everything runs on the dedicated socket `tmux -L mocha`. Managed sessions get `escape-time 10`, `focus-events on`, `status off`, `mouse on`.
- Test sessions in use: `mocha-phone` (owner's), `mocha-sim`, `mocha-uitest` (kill leftover streaming loops with `C-c` before reuse).

## Transport quick reference

- Terminal WS: `/api/sessions/{id}/terminal` or `/api/agents/{pane}/terminal`, subprotocol `mocha.v2` (v1 legacy), Bearer token auth. Resume: `?stream=<epoch>&resume=<offset>`. Full spec: [`../protocol/README.md`](../protocol/README.md).
- Agent events WS: `/api/events`, subprotocol `mocha.events.v1` — full agent snapshot on connect and on every change.
- Project picker: `GET /api/projects` (recent folders + root scan + roots); `POST /api/herdr/tabs` requires an absolute existing `cwd` and refuses one outside the roots unless the request confirms with `allowOutsideRoots`. Full shapes: [`../protocol/README.md`](../protocol/README.md).
- Agent kinds the picker offers are detected by the host via the user's **login shell** (`$SHELL -lc 'command -v <kind>'`), cached 60 s — the launchd service has a bare PATH, so plain `which` would miss anything in `~/.local/bin` or a version manager. Catalog: `apps/host/src/agent-kinds.ts` (mirrors `herdr agent start --kind`).
- Project roots come from `MOCHA_ROOTS` (comma-separated), defaulting to whichever of `~/Code`, `~/Projects`, `~/Developer`, `~/Documents` exist. They are both the picker's browsable list and the guardrail on where a phone-created agent may start. The host's recent-folder list lives in `~/.mocha/projects.json` (0600) and holds the last 12 folders it launched an agent in.
- Herdr contract and traps: [`HERDR_INTEGRATION.md`](./HERDR_INTEGRATION.md).
