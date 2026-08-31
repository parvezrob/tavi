# Mocha feature landscape

**Research date:** 2026-08-19
**Purpose:** evidence-backed feature inventory and prioritization for product planning

## 1. How to read this document

This is not a checklist to copy wholesale. Competitor features are evidence that a problem is real, not proof that Mocha should implement the same solution. Recommendations are filtered through the product thesis: direct-first, host-owned, attention-first, provider-neutral, and terminal-compatible without becoming an agent harness.

Priority labels:

- **Now:** necessary for the first differentiated release.
- **Next:** high-value after the intervention loop and terminal reliability are proven.
- **Later:** valuable but expands transport, platform, or provider surface.
- **Avoid:** conflicts with the product thesis or creates disproportionate risk.

## 2. Product landscape summary

| Product/category | Strongest public features | Structural tradeoff for our target user |
| --- | --- | --- |
| Codex Remote | Native control plane, hosts/workspaces/worktrees, queue vs steer, approvals, inline review, attachments, goals | OpenAI-specific. |
| Claude Code Remote Control | Continue local session on web/mobile, push, local tools/files remain available | Claude-specific; synchronized transcript stored through Anthropic while active. |
| GitHub Copilot Remote | Monitor/steer local CLI sessions and approve requests from GitHub Mobile | Copilot/GitHub-specific. |
| Orca | Multi-host status, terminal/chat, files, source control, browser, account usage, workspace creation | Desktop/server product remains source of truth; broad harness/ADE surface. |
| T3 Code | Open multi-provider control plane across web/desktop/mobile, direct/Tailscale/tunnel paths | Explicit agent harness and provider-adapter maintenance. |
| Happy/Happier | Cross-provider chat, E2EE, push, offline history, QR pairing | Requires wrapper/companion CLI and hosted synchronization model. |
| Moshi | Ghostty/Metal terminal, SSH/Mosh/ET, tmux/Herdr/Zellij, hooks, chat, diff, files, browser preview, voice, Live Activities, Watch | Strong proof of the native terminal pattern; extremely broad feature surface and some desired capabilities are paid. |
| Agentmux | Native SSH terminal, tmux, Live Activities, file browser/editor, Markdown, images, Shortcuts | More mobile remote workspace than narrow agent attention layer. |
| ShadowTerm | SSH/Mosh, tmux/Herdr, custom keyboards, SFTP/editor, monitoring, widgets, approvals | Very broad server-operations and terminal surface. |
| Remux | SwiftUI + Ghostty, direct SSH, mobile tmux model, pane previews, attachments, file/dev preview | tmux-first; attention semantics are limited compared with an agent control plane. |
| Herdr | Durable workspaces plus agent status rollups, direct attach, CLI/JSON/socket APIs | Requires Herdr adoption for richest state. |

## 3. Ranked feature recommendations

### A. Connectivity and durability

| Feature | Evidence | Mocha decision | Priority |
| --- | --- | --- | --- |
| Direct private network path | Tailscale documents direct connections as lowest-latency/highest-throughput; user observed a major difference. | Tailscale Serve recommended; LAN/private HTTPS supported; no mandatory relay. | Now |
| Connection-path visibility | Tailscale can report direct, DERP relay, or peer relay. | Show path and latency when detectable; never imply direct when unknown. | Now |
| Durable multiplexer sessions | tmux appears across Orca, Moshi, Agentmux, Remux, Happy/Happier; Herdr adds agent semantics. | Herdr is the only provider (tmux lane removed, #53). | Now |
| Safe automatic reconnect | Every serious mobile terminal claims reconnect or session recovery. | Treat backgrounding and network switching as normal; resubscribe and resize safely. | Now |
| Mosh roaming/local echo | Mosh and Moshi emphasize responsiveness under loss and IP changes. | Re-evaluate after native WS reconnect benchmark; do not add second transport prematurely. | Later |
| Hosted fallback relay | Orca/T3/Happy-style systems improve reachability at cost of infrastructure and trust surface. | Only after measuring how many users cannot form a usable direct/peer-relay path. | Later |

### B. Session organization and attention

| Feature | Evidence | Mocha decision | Priority |
| --- | --- | --- | --- |
| Unified multi-host session list | Orca and T3 aggregate hosts; user explicitly wants several laptops/computers. | Single home across hosts. | Now |
| Needs-attention queue | Herdr rolls blocked/working/done upward; Moshi has agent inbox; vendor apps surface approvals. | Primary home section and product differentiator. | Now |
| Exact session/pane resume | Multiplexer-native products expose windows/panes and one-tap attach. | Persist host + provider + workspace/session + pane identity. | Now |
| State provenance | Herdr documents lifecycle hooks vs screen manifests; generic terminals cannot reliably know. | Display the source; unknown is a first-class state. | Now |
| Recent output preview | Orca hydrates scrollback; Remux offers live pane previews. | Bounded safe preview before opening terminal. | Now |
| Worktree creation | Codex Remote, Orca, and T3 treat worktrees as core parallel-agent context. | Start with project/cwd + session; add worktree creation only after core loop. | Next |
| Agent usage/rate-limit dashboard | Orca and Moshi expose it. | Useful but not central; provider-specific and subject to churn. | Later |
| Vanity productivity metrics | Orca screenshot shows agents spawned/time/PRs. | Do not lead with them; they do not help the next intervention. | Avoid |

### C. Mobile terminal ergonomics

| Feature | Evidence | Mocha decision | Priority |
| --- | --- | --- | --- |
| Native high-performance renderer | Moshi and Remux use Ghostty on iPhone; Moshi documents Metal GPU rendering and replaced xterm.js with Ghostty. | GhosttyKit/Metal locked for v1; pin and own the integration, qualify every upgrade on physical devices. | Now |
| Multiline composer | Mobile chat products reduce direct terminal typing. | Primary prompt entry; explicit send/Enter behavior. | Now |
| Terminal accessory row | Orca, Moshi, Agentmux, ShadowTerm expose hard-to-type keys. | Esc, Tab, Shift-Tab, Ctrl, arrows, interrupt, customizable slots. | Now |
| Live typing mode | Orca distinguishes reply/composer from direct live input. | User-controlled mode with visible state. | Now |
| Copy/paste and OSC 52 | Moshi, Agentmux, ShadowTerm call this out. | Support with security preference and clear clipboard feedback. | Now |
| Hardware keyboard | Competitive mobile terminal tools support it. | Correct terminal key handling in the iPhone-first client; iPad-specific layout and focus optimization follows after V1. | Now |
| CJK/IME and wide-glyph correctness | Moshi and Agentmux explicitly address it; terminal engines often fail here. | Include in renderer corpus and acceptance tests. | Now |
| Gestures/D-pad/custom keyboard layouts | Moshi and ShadowTerm go deep. | Start with a small excellent control row; add customization from usage evidence. | Next |
| Voice input | Moshi, Orca, ShadowTerm and vendor apps support it. | On-device dictation into composer after core input is stable. | Next |
| Predictive local echo | Mosh's core advantage on high-latency links. | Do not invent at application layer; inherit through Mosh if adopted. | Later |

### D. Notifications and ambient surfaces

| Feature | Evidence | Mocha decision | Priority |
| --- | --- | --- | --- |
| Push on completion/decision | Claude Remote, Orca, Happy, Moshi. | Explicit event sources only; no fragile output scraping. | Next |
| Live Activities / Dynamic Island | Moshi and Agentmux. | Show active/waiting state after event model is reliable. | Next |
| Apple Watch approvals | Moshi. | Attractive short-intervention surface, but defer until phone flow is trusted. | Later |
| Widgets/App Intents | Agentmux/ShadowTerm and native platform direction. | Recent hosts/status and safe shortcuts after App Store release. | Later |

### E. Context, review, and files

| Feature | Evidence | Mocha decision | Priority |
| --- | --- | --- | --- |
| Diff viewer | Codex Remote, Orca, Moshi, T3-style clients. | Read-only review first; explicit handoff to terminal for commands. | Next |
| Changed-file/source-control actions | Orca supports stage/unstage/commit. | Add review before write actions; confirmation and repository state checks. | Later |
| Photo/file upload | Orca, Moshi, Agentmux, Remux. | Upload to selected session cwd, preview and confirm remote path. | Next |
| File tree and preview | Orca, Agentmux, Remux, ShadowTerm. | Read-only code/Markdown/image/PDF preview; avoid full editor initially. | Next |
| Path and URL recognition | Remux/Agentmux turn terminal text into native actions. | Tappable links now; file-path actions with cautious parsing next. | Next |
| Local dev-server preview | Orca, Moshi, Remux. | Private forwarding through host; WebKit view; no public tunnel. | Next |
| Full code editor | Orca/Agentmux/ShadowTerm have editor features. | Scope trap for the core product; add only if user data shows repeated laptop fallback for tiny edits. | Avoid for early releases |

### F. Chat and provider intelligence

| Feature | Evidence | Mocha decision | Priority |
| --- | --- | --- | --- |
| Native chat projection | Codex/Claude native, Orca, Moshi, T3, Happy. | One session with `Terminal | Chat`; capability-based and authority-labeled. Codex uses official app-server; Claude follows the separate auth/compliance path. | Next |
| Structured approvals | Vendor apps and Codex app-server expose them; Herdr can detect/report blockers. | Herdr/event-based first; Codex official adapter later. | Next/Later |
| Queue vs steer | Codex Remote highlights this as a key mobile decision. | Add only for providers that expose semantics; generic terminal send is immediate. | Later |
| Provider adapter matrix | T3 maintains adapters across providers and surfaces. | Avoid broad adapter race; one official adapter at a time behind stable capabilities. | Later |
| Terminal transcript scraping as chat | Can appear universal but is brittle and can misread alternate screens, redraws, and secrets. | Do not use as authoritative foundation. | Avoid |

### G. Security and trust

| Feature | Evidence | Mocha decision | Priority |
| --- | --- | --- | --- |
| Keychain credentials | Moshi, Agentmux, Remux, ShadowTerm. | Required. | Now |
| Per-device pairing and revoke | Companion systems use QR pairing; shell access has high blast radius. | Single-use QR bootstrap → per-device credential → host revoke. | Now |
| Biometrics | Moshi and vendor trusted-device flows use device authentication. | Optional Face ID app/action gate. | Now |
| Host-key/certificate verification | Direct SSH products expose host verification. | TLS endpoint/fingerprint verification and matching host identity. | Now |
| No account/no relay mode | Remux emphasizes direct SSH; Mocha's core promise. | Default architecture and messaging. | Now |
| End-to-end encrypted hosted sync | Happy/Happier differentiate here. | Required only if an optional relay/sync service is built. | Later |
| Provider OAuth token extraction | Increases compromise and terms risk. | Never. | Avoid |
| Claude.ai login or subscription routing in Mocha | Anthropic explicitly directs product developers to API-key/cloud-provider authentication and prohibits third-party Claude.ai login/subscription routing. | Never; terminal-control mode leaves the official Claude Code CLI authenticated locally. | Avoid |

## 4. Recommended feature stack by release

### Release 0: benchmark and workflow proof

- Attention Queue clickable prototype.
- Pinned GhosttyKit/Metal XCFramework, remote-I/O adapter, and physical-iPhone lifecycle qualification.
- SwiftTerm retained only as a documented contingency if Ghostty exposes a release-blocking defect.
- Current host bridge over Tailscale.
- One tmux session, composer, key row, background/foreground reconnect.
- Connection path/latency logging.

### Release 1: private native control plane

- QR pairing and multi-host home.
- Herdr provider (tmux lane removed, #53).
- Needs attention, active, recent, unknown.
- Exact resume and native terminal.
- Direct-path diagnostics.
- Keychain, biometrics, per-device revoke.
- Demo mode and App Review package.

### Release 1.1: context and ambient attention

- Explicit-event notifications and Live Activities.
- Diff, files, images, Markdown, dev preview.
- Voice composer and saved quick actions.
- Worktree-aware launch.

### Release 2: progressive provider intelligence

- Codex official app-server adapter running locally behind the host.
- Structured chat, approvals, history, queue/steer where supported.
- Evaluate a documented Claude adapter only if it can meet the no-token-extraction and terminal-fallback rules.
- Android client begins after protocol and intervention metrics are stable.

## 5. Feature evaluation rubric

Every proposed feature should score against these questions:

1. Does it shorten time to identify or unblock the right session?
2. Does it work across providers, or degrade cleanly when it cannot?
3. Can it remain direct and host-owned?
4. Does it preserve terminal fallback?
5. Is its state trustworthy and explainable?
6. Does it improve a phone interaction rather than reproduce a desktop workflow?
7. Can it be tested on a physical phone under network change and backgrounding?
8. Does it increase App Review, credential, or provider-terms risk?

Features failing the first six questions should not enter the near-term roadmap even if competitors have them.

## 6. Source links

- [OpenAI Codex Remote guide](https://developers.openai.com/blog/mastering-codex-remote-for-engineering)
- [OpenAI Codex app-server](https://developers.openai.com/codex/app-server)
- [OpenAI Codex authentication](https://developers.openai.com/codex/auth)
- [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control)
- [Claude Code legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)
- [Claude Code authentication](https://code.claude.com/docs/en/authentication)
- [Claude Code hooks](https://code.claude.com/docs/en/hooks)
- [GitHub Copilot remote control](https://github.blog/news-insights/product-news/take-your-local-github-sessions-anywhere/)
- [Orca mobile](https://www.onorca.dev/docs/mobile)
- [T3 Code](https://github.com/pingdotgg/t3code)
- [Happy](https://github.com/slopus/happy)
- [Moshi](https://getmoshi.app/docs)
- [Moshi: Ghostty/Metal terminal-engine explanation](https://getmoshi.app/compare/blink)
- [Moshi App Store release history](https://apps.apple.com/jo/app/moshi-ssh-mosh-terminal/id6757859949)
- [Agentmux](https://apps.apple.com/us/app/agentmux/id6766158521)
- [ShadowTerm](https://apps.apple.com/us/app/shadowterm-ssh-mosh-terminal/id6746274402)
- [Remux](https://github.com/h3nock/remux)
- [Herdr agents](https://herdr.dev/docs/agents/)
- [Mosh](https://mosh.org/)
- [Tailscale connection types](https://tailscale.com/docs/reference/connection-types)
