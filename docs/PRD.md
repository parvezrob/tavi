# Mocha product requirements document

**Status:** Approved for initial implementation
**Version:** 0.2
**Updated:** 2026-08-19
**Owner:** Product / Engineering
**Initial release:** Native SwiftUI, iOS 26 minimum, iPhone first

## 1. Product summary

Mocha is a native mobile control plane for terminal coding agents running on computers the user controls. It aggregates durable Herdr agent sessions across hosts, identifies sessions needing attention when a trustworthy signal exists, resumes the exact terminal, and enables short, safe interventions from a phone.

Mocha does not run models, proxy provider API calls, or replace Codex, Claude Code, or other official CLIs.

## 2. Problem statement

Developers cannot reliably leave long-running coding agents unattended because agents frequently finish, request permission, or need clarification. Existing remote products are provider-locked, harness-dependent, relay-sensitive, desktop-centric, or designed as general terminals rather than an agent supervision surface.

## 3. Product goal

Enable a user away from their computer to identify, inspect, and unblock the right coding session in seconds, with a direct and private connection and without changing how the agent runs on the host.

## 4. Non-goals

- Build a model router, agent framework, or orchestration runtime.
- Reimplement vendor conversation storage.
- Manage or sell provider accounts/subscriptions.
- Require a hosted Mocha relay.
- Build a full mobile IDE in v1.
- Parse arbitrary terminal output into authoritative agent state.
- Support Android before the iOS workflow and protocol are validated.
- Attach to arbitrary processes that were not started in a durable terminal or exposed by a supported provider.

## 5. Users and primary scenarios

### User A: single-machine mobile intervention

Starts Codex or Claude Code in Herdr on a Mac, leaves the desk, receives or notices a waiting session, reads the immediate context, sends an answer, and disconnects.

### User B: multi-host supervisor

Has a laptop, desktop, and remote devbox. Opens one home screen, sees status and connection health for every host, and resumes a specific session without remembering addresses or multiplexer commands.

### User C: terminal fallback

Runs an unsupported CLI or ordinary shell. Mocha cannot supply structured status, but it can still list, attach, reconnect, and provide a high-quality native terminal.

## 6. Product principles

- Attention before inventory.
- Direct connection by default.
- Host is the source of truth.
- Disconnect is normal.
- Typing is expensive.
- Unknown state is better than wrong state.
- Structured views must always offer terminal fallback: every agent on the home opens its real terminal.
- Provider integrations are optional capabilities, never the runtime foundation.

## 7. V1 release scope

### 7.1 App shell and onboarding

- Native SwiftUI app with a minimum deployment target of iOS 26, optimized for iPhone in V1.
- Product/target/module name `Mocha`, bundle identifier `com.parvezrob.mocha`, and durable internal namespace `mocha`.
- iPad-specific layout and interaction optimization is planned after the iPhone V1 and is not an initial release gate.
- Dark-first, Orca-clean visual baseline: near-black canvas, quiet charcoal groups, restrained borders, system typography, consistent radii, and sparse semantic color. Avoid glow, gradients, ornamental depth, and dashboard spectacle.
- System-provided Liquid Glass for the functional layer—navigation, toolbars, menus, sheets, and tab surfaces—not custom glass containers in the content layer.
- V1 visual target is [`assets/agent-deck-v1-home-terminal.png`](./assets/agent-deck-v1-home-terminal.png) (predates the #26 grouping — see §7.3): an attention-first Home with live resumable session previews, a compact labeled `Sessions | Inbox` glass dock plus separate new-connection action, and a terminal-first Herdr screen with a native `Jump to` workspace/tab sheet.
- V1 pairing target is [`assets/agent-deck-v1-pairing-flow.png`](./assets/agent-deck-v1-pairing-flow.png): scan first, verify the exact host and fingerprint at the moment of consent, show connection checks progressively, then land on discovered sessions.
- Opaque terminal and dense content backgrounds.
- Built-in interactive demo host requiring no external app, account, or network.
- Onboarding explains host ownership, Tailscale recommendation, security consequences, and pairing.

### 7.2 Host pairing and management

- Pair by scanning a QR code generated on the host.
- Manual endpoint and one-time code entry as fallback.
- Pairing exchanges a single-use secret for a device-specific credential.
- Store credentials in iOS Keychain.
- Name, reorder, reconnect, edit, and remove hosts.
- Display connection health, last seen, round-trip latency, and path classification when detectable.
- Support private HTTPS endpoints; Tailscale Serve is the recommended remote path.
- Pairing completion explicitly states that closing or disconnecting the phone does not stop Herdr sessions.

### 7.3 Home and attention queue

- First section: sessions requiring attention — always flat and on top, across every computer and project, so a waiting agent never hides under a group.
- Below it (#26): computer → project → agents. A project is the agent's working directory (basename; "Home" for the home folder), nothing to name or maintain. Running agents are full cards under their folder; done/idle agents share a compact card with their status word. A folder whose only agent is waiting keeps its header (it counts the agent) and never repeats it.
- Host availability remains visible but secondary; the computer header is the host dimension multi-host (#50) nests under.
- The group headers carry host and project; each row carries provider, state, state source, recent timestamp, and (for running/waiting agents) a short safe preview.
- One tap resumes the exact session target.
- Unknown/unclassified sessions are clearly labeled and remain accessible.

### 7.4 tmux provider

Removed (#53, 2026-08-31). Herdr is the only backend; there is no separate multiplexer lane. Kept as a heading so cross-references resolve.

### 7.5 Herdr provider

- Discover workspaces, tabs, panes, and detected agents.
- Read semantic state and its authority/provenance.
- Use state rollups for the attention queue.
- Attach directly to an agent or terminal when supported.
- Resume exact workspace/tab/pane.
- Subscribe to or poll events using a documented Herdr interface.
- Fall back to a terminal attach if a richer operation is unavailable.

### 7.6 Native terminal

- GhosttyKit terminal engine rendered with Metal, supplied through a pinned, reproducibly built XCFramework.
- Terminal integration isolated behind `AgentTerminalView`; Ghostty upgrades require physical-device qualification and an explicit version decision.
- VT/xterm-compatible rendering suitable for Codex, Claude Code, shells, and Herdr.
- True color, Unicode, emoji, combining characters, and wide glyphs.
- Low-latency streaming and resize.
- Selection, copy, paste, and OSC 52 clipboard support with a security preference.
- Tappable hyperlinks.
- Software keyboard and hardware keyboard support.
- Mobile control row: Esc, Tab, Shift-Tab, Ctrl, arrows, Enter, interrupt, and customizable slots.
- Multiline composer that sends text deliberately rather than on every keystroke.
- Optional live typing mode for terminal-native interaction.
- Pinch or settings-based font size (shipped 2026-08-31, #51: one persisted preference, Settings slider + terminal pinch, grid readout).
- VoiceOver labels for surrounding controls; terminal accessibility quality documented honestly.
- Recover focus and input correctly after sheets, app backgrounding, and reconnect.

### 7.7 Optional conversation view

- `Terminal` and `Chat` are sibling views of the same durable session; opening Chat never starts a hidden second agent.
- Chat appears only when the adapter advertises `conversation.read` and `conversation.send`.
- Every message, tool card, approval, and state includes source authority and freshness.
- Codex structured chat uses the official local app-server through the host, with honest client identity and no provider credential crossing the Mocha protocol.
- Claude Code subscription sessions remain official interactive CLI sessions controlled through the terminal; Mocha does not offer Claude.ai login or handle Claude subscription OAuth.
- A fully structured Claude product adapter requires API-key or supported cloud-provider authentication kept on the host.
- Local Claude conversation projection is opt-in, local-only, visibly labeled, kill-switchable, and release-gated on current terms review or written clarification.
- Unsupported or ambiguous content falls back visibly to `Open terminal`; it is never converted into a fabricated structured action.
- Chat navigation and data types remain provider-neutral while Codex and Claude Code receive first-class setup, compatibility testing, and accurate identity.

### 7.8 Reliability

- Herdr owns process lifetime; the phone connection never owns agent lifetime.
- Automatically reconnect after brief network loss, app foreground, and endpoint changes.
- Resume with an explicit stale/offline indicator until the latest state is confirmed.
- Apply backpressure and bound terminal scrollback/memory.
- Preserve the user's selected host and session target across app restarts.
- Never replay ambiguous unsent input after reconnect.

### 7.9 Security

- Host binds to localhost by default.
- Production connection requires TLS.
- Per-device credentials; revocable at the host.
- Keychain storage and optional Face ID gate.
- No provider credentials cross the Mocha protocol.
- Redact secrets from logs and diagnostics.
- Warn against public port exposure and Tailscale Funnel.
- Confirm file upload, session destruction, and other high-impact actions.
- Provide a “lock now” action that removes decrypted in-memory credentials and disconnects.

## 8. V1.1 candidate scope

- Push notifications from explicit Herdr/provider events.
- Live Activities / Dynamic Island for active or waiting sessions.
- Diff and changed-file viewer.
- Photo/file upload to the active working directory with preview and confirmation.
- File tree plus code/Markdown/image/PDF preview.
- Private localhost/dev-server preview.
- Saved quick prompts and commands.
- On-device dictation to the composer.
- Optional direct SSH connection mode.
- Connection diagnostics with Tailscale direct/relay troubleshooting guidance.

## 9. Later scope

- Optional `Terminal | Chat` switch against the same durable session.
- Codex rich adapter via the official local app-server behind the Mocha host protocol.
- Claude enhanced terminal projection only after current terms review; fully structured Claude adapter uses API-key/cloud-provider authentication.
- Structured approvals, tool events, queued versus steering prompts only where an authoritative capability exists.
- Additional provider adapters only when a documented interface exists.
- Mosh transport if user research shows persistent roaming pain after reconnect improvements.
- Apple Watch approvals and status.
- iOS widgets and App Intents.
- Android native app against the stable protocol.
- Optional managed relay only if a direct path cannot satisfy enough users and the privacy/performance model is explicit.

## 10. Functional requirements

| ID | Requirement | Priority | Acceptance summary |
| --- | --- | --- | --- |
| FR-001 | Pair a host through QR | Must | New device receives a revocable credential without manual token copying. |
| FR-002 | List multiple hosts | Must | Online/offline/unknown states and last seen are correct after refresh. |
| FR-003 | List Herdr agents | Must | Existing agents appear without changing or restarting them. |
| FR-004 | List Herdr workspaces/agents | Must | Hierarchy, status, and provenance match Herdr's documented output. |
| FR-005 | Exact one-tap resume | Must | Card opens the correct host and terminal target. |
| FR-006 | Native interactive terminal | Must | Reference TUI corpus renders and accepts input on physical iPhone. |
| FR-007 | Multiline prompt composer | Must | User can edit before sending and intentionally append Enter. |
| FR-008 | Mobile terminal controls | Must | Common control keys work without opening another sheet. |
| FR-009 | Automatic reconnect | Must | Foreground/network-switch recovery restores the same target safely. |
| FR-010 | Honest attention queue | Must | Only trusted sources produce semantic state; unknown is shown otherwise. |
| FR-011 | Demo mode | Must | Reviewer can exercise dashboard, status, terminal, and reconnect states offline. |
| FR-012 | Device revocation | Must | Revoked credential fails immediately and receives no new terminal data. |
| FR-013 | Recent safe preview | Should | Session list shows bounded output with privacy controls. |
| FR-014 | Connection path diagnostics | Should | App reports direct/relay/unknown when host evidence is available. |
| FR-015 | iPad adaptive layout | Later | Post-iPhone plan provides a sidebar/detail layout and hardware-keyboard optimization. |

## 11. Non-functional requirements and targets

Targets are product goals to test, not current measurements.

| Area | Target |
| --- | --- |
| Cached launch | Useful dashboard visible in under 1 second on a supported recent iPhone. |
| Connected terminal first paint | Under 500 ms after a healthy session socket opens on a low-latency tailnet. |
| Input feedback | No app-added delay perceptible during direct-path use; instrument input-to-host and host-to-render separately. |
| Scrolling / animation | Sustain 60 fps for normal terminal and dashboard interactions on the oldest supported test device. |
| Reconnect | Restore the previous target within 2 seconds after a healthy connection is available. |
| Crash-free sessions | At least 99.5% during beta before App Store submission. |
| Memory | Bounded scrollback and previews; no unbounded growth during an eight-hour host session. |
| Accessibility | Dynamic Type outside terminal; VoiceOver-labeled controls; Reduce Motion and Increase Contrast respected. |
| Privacy | No analytics, crash log, or notification payload contains terminal content by default. |
| Compatibility | iOS 26 and later for V1; no earlier deployment target. |

## 12. Information architecture

The complete V1 route and state contract lives in [`V1_SCREEN_AND_NAVIGATION_MAP.md`](./V1_SCREEN_AND_NAVIGATION_MAP.md).

1. **Sessions root** — Needs attention, Active, and Recent across trusted hosts.
2. **Inbox root** — unresolved attention events and resolved history.
3. **New action** — separate from the dock; pair a computer or create a terminal session.
4. **Request detail** — bounded trustworthy context, capability-gated actions, and explicit terminal fallback.
5. **Terminal** — focused full-screen Ghostty surface, quick controls, composer, and provider-aware `Jump to` sheet.
6. **Host management** — contextual health sheet, host detail, diagnostics, paired devices, and revocation.
7. **Settings** — contextual security, terminal, controls, privacy, demo, and support; not a root tab.

## 13. Core flows

The complete end-to-end journey, failure paths, and measurement plan live in [`CUSTOMER_JOURNEY.md`](./CUSTOMER_JOURNEY.md). The product is optimized for a 20–60 second remote intervention, with a full terminal as the universal compatibility and recovery layer.

### Pair

Host CLI displays QR → app scans immediately → user verifies matching host name/fingerprint and shell-level access → single-use pairing exchange → progressive identity/TLS/path/session checks → credential stored → reminder that phone disconnect is safe → first host home.

### Resume and unblock

Open → Needs attention → tap session → recent context appears → resume exact terminal → send response or control key → observe state transition → dismiss.

### Recover from network switch

Session becomes stale → app prevents ambiguous send → reconnect with backoff → resize and resubscribe → fetch fresh status/output → enable input → show recovered indicator.

### Leave safely

Observe the state transition or fresh output → detach or background the app → Herdr continues to own the process → return later to the same exact target.

### Recover from an offline or untrusted state

Show cached context as stale → display last seen and path diagnostics → withhold semantic claims and ambiguous sends → reconnect or guide the user to wake/repair the host → fall back to the exact terminal when structured capabilities are unavailable.

## 14. State model

| Display state | Meaning | Acceptable authority |
| --- | --- | --- |
| Needs attention | Explicit approval/question/blocking input is known. | Herdr lifecycle authority, documented provider protocol, explicit Mocha hook. |
| Working | Agent is actively processing or executing. | Herdr lifecycle authority, provider protocol, declared screen manifest with provenance. |
| Done / ready to review | Work completed since the user last viewed it. | Herdr rollup/event or provider protocol. |
| Idle | Session exists and is not known to be active/blocked. | Multiplexer plus authority-specific state. |
| Unknown | Session exists but semantic state is unavailable or stale. | Default for a pane without a trustworthy status source (e.g. a plain shell). |
| Offline | Host cannot currently be reached. | Connection layer. |

## 15. Success criteria

### MVP validation

- 20 real founder interventions without session loss.
- Median open-to-correct-session time under 5 seconds in dogfood tests.
- At least 80% of intervention attempts completed without opening the laptop.
- No false `Needs attention` label in the initial test corpus.
- Network switch and background/foreground reconnect pass on Wi-Fi and cellular.

### Beta validation

- Five external testers use the product for at least one week.
- At least 70% of observed use is monitor/unblock/steer rather than prolonged terminal typing, supporting the control-plane thesis.
- Qualitative trust: testers understand where execution happens and why a state label is shown.

## 16. Open decisions

- Initial pinned Ghostty commit/fork and the smallest downstream patch set required for custom remote I/O and safe surface teardown.
- Whether notification fan-out can remain direct/local or needs an optional service.
- Whether manual LAN HTTPS is sufficient for App Review alongside demo mode.
- Exact provider/state capabilities exposed in the first Herdr integration.
