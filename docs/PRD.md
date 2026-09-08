# Tavi product requirements document

**Status:** Approved for initial implementation
**Version:** 0.2
**Updated:** 2026-08-19
**Owner:** Product / Engineering
**Initial release:** Native SwiftUI, iOS 26 minimum, iPhone first

## 1. Product summary

Tavi is a native mobile control plane for terminal coding agents running on computers the user controls. It aggregates durable Herdr agent sessions across hosts, identifies sessions needing attention when a trustworthy signal exists, resumes the exact terminal, and enables short, safe interventions from a phone.

Tavi does not run models, proxy provider API calls, or replace Codex, Claude Code, or other official CLIs.

## 2. Problem statement

Developers cannot reliably leave long-running coding agents unattended because agents frequently finish, request permission, or need clarification. Existing remote products are provider-locked, harness-dependent, relay-sensitive, desktop-centric, or designed as general terminals rather than an agent supervision surface.

## 3. Product goal

Enable a user away from their computer to identify, inspect, and unblock the right coding session in seconds, with a direct and private connection and without changing how the agent runs on the host.

## 4. Non-goals

- Build a model router, agent framework, or orchestration runtime.
- Reimplement vendor conversation storage.
- Manage or sell provider accounts/subscriptions.
- Require a hosted Tavi relay.
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

Runs an unsupported CLI or ordinary shell. Tavi cannot supply structured status, but it can still list, attach, reconnect, and provide a high-quality native terminal.

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
- Product/target/module name `Tavi`, bundle identifier `com.farfield.tavi`, and durable internal namespace `tavi`.
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
- Home v3 (owner + Fable 5.1 design pass, 2026-09-02): the home is two kinds of object and nothing else — a labelled section (`NEEDS YOU 5`, `PROJECTS`, small caps with the count trailing; amber only on needs-you) and a card of rows. Every row shares one skeleton: a glyph tile that says which kind of agent (Claude Code ✳, Codex `</>`, shell `>_`; amber while it waits on you, quiet otherwise), a primary line that says *which one* (your tab name or the agent's own title, else its folder), a quiet secondary line (the kind, plus the computer when several are on screen), and one trailing fact. No banner: the section header carries the count, so nothing is said twice.
- The waiting section is one card of rows (primary identity, `Claude Code · computer`, the line the agent is asking on when the host has one, how long it has waited) — never a column of full cards (owner, 2026-09-02: five cards read as a wall) and never a banner above a block (same day: two amber stripes stacked). A row opens the decision sheet; rows that open a sheet have no chevron, rows that push the terminal do. Waiting agents the phone cannot tell apart — same computer, kind, identity line, and asking line (in practice herdr-restored blank `claude --resume` panes) — stack into one row (`Home · Claude Code · 3 waiting, nothing on screen`, amber count) that expands in place to its members, labelled by herdr's raw tab label or pane id; the section count still counts every agent. A real question is part of the key, so it never merges with a different one.
- Below it (#26): project → agents, each folder **one card**: header (folder name, computer trailing when several, path as the quiet mono second line — a folder name never stands in for a place), then its agents as rows. Running agents lead the card with a short excerpt of their screen; done rows are one line with "Done" and how long ago; idle rows say nothing — idle is the resting state, the tile dims instead (owner call 2026-09-02) — and VoiceOver still reads the state. A project is the agent's working directory (basename; "Home" for the home folder), nothing to name or maintain. A folder whose every agent is waiting above renders nothing here (2026-09-02; supersedes the earlier "keeps its header" rule). Herdr's pane title is shown only when it is a name a person would recognise: a command line (`claude --resume …`) is not identity.
- Several computers (#50, owner call 2026-09-02): the computer is context, not the hierarchy. A chip strip at the top of the home — `All`, then one chip per computer in pairing order with its health dot (and the health word when not live: Reconnecting / Offline / Unpaired / Connecting…) and an amber numeral for how many of its agents are waiting — filters the home; the sessions below stay **one list by state** across every computer shown, with each project card naming its computer and needs-you rows saying `Claude Code · computer`. With one computer the strip is a single status pill without the numeral (the header beneath already counts). Latency, address, fingerprint, rename, and unpair live in the computer's own sheet (a tap on the single pill, long-press on a chip, the Computers menu, Settings → Paired computers), where the one-line summary reads `Live · 40 ms · 8 agents · 5 waiting`. A computer that is asleep, unreachable, or unpaired gets one card under the strip; its last known cards stay listed. Computer names are the short form of what the machine reported (`Parvezs-MacBook-Air` → `MacBook Air`) unless you rename it.
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
- Codex structured chat uses the official local app-server through the host, with honest client identity and no provider credential crossing the Tavi protocol.
- Claude Code subscription sessions remain official interactive CLI sessions controlled through the terminal; Tavi does not offer Claude.ai login or handle Claude subscription OAuth.
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
- No provider credentials cross the Tavi protocol.
- Redact secrets from logs and diagnostics.
- Warn against public port exposure and Tailscale Funnel.
- Confirm file upload, session destruction, and other high-impact actions.
- Provide a “lock now” action that removes decrypted in-memory credentials and disconnects.

### 7.10 Files: changed, mentioned, browse (#25, #57, #61 — shipped 2026-09-02)

- One **Files** sheet per agent (terminal toolbar; long-press a home row → "What it changed"), three lists: **Changed** (the default from the home — `git status` of the repository containing the agent's cwd, with `+n −n`, state word, one unified diff per file on tap), **Mentioned** (the default from the terminal — path-like tokens the agent printed, scanned on the phone from the terminal's own transcript, offered only when the host confirms they exist; anything outside the roots or a secret is listed as refused, never hidden), **Browse** (the fallback — one folder at a time from the agent's cwd, gitignored entries dimmed and last, never hidden).
- One read-only viewer: Markdown rendered as blocks, code monospaced with line numbers and scrolled to the `:line` the agent printed, images, PDFs, diffs with additions/deletions coloured (the theme's one muted red exists for this alone). Truncation ("first 1 MB of 3 MB") and refusals ("binary, 2.3 MB"; "looks like credentials") are said in words. Share hands the text off. No edit, rename, or delete anywhere — the host has no route for them.
- Host contract: `protocol/README.md` → `/api/changes`, `/api/changes/file`, `/api/files`, `/api/files/stat`, `/api/files/content`, `/api/files/raw`. Every path is joined to the agent's cwd, **realpath'd, then** checked against the configured roots (themselves realpath'd) — a symlink out of a root is refused after realpath. Secrets are refused by name (`.env*`, keys, `credentials`/`secret`, `.npmrc`…) in previews and diffs. Three fixed git reads, no mutating operation on the path.

### 7.11 Private dev-server preview (#58 — shipped 2026-09-02)

- An agent starts something on `localhost:<port>`; the person sees it on the phone **without starting the server any differently** — no `--host`, no tunnel, no URL to copy. **Preview** sits beside Files in the terminal toolbar (lit when the transcript names a loopback port — scanned on the phone, at zero cost to the computer) and on a project row's long-press. One running server → straight to a one-sentence consent ("The node process in preview-demo will be viewable from this phone until you close it. Only this phone can open it, through your tailnet."), asked once per computer and port per app launch. Otherwise a chooser: what is running in this folder (host `lsof`, only when asked), what the terminal mentioned, or a typed port. The page opens full screen at real iPhone size in a `WKWebView` with a **non-persistent data store**; hot reload flows (WebSocket piped). A menu offers Reload, Another port, and **Stop server…** (confirm → the host `SIGTERM`s only this project's owner of that port). A bottom banner says when the server stopped or the preview ended, with Reopen. **Open means reachable, closed means gone**: Done ends the preview on the computer at once; a killed app or lost network ends it two minutes after the last heartbeat. No duration setting by design.
- Trust: one **door** per computer — `pair` publishes `https://<name>.ts.net:8443` → the host's loopback preview listener once and never per preview. The door forwards only for a **ticket** cookie minted over the bearer-authenticated API and bound to one device and one loopback port; without one it says "Open this from Tavi" (401). The device credential never enters the web view; the dev app never sees the ticket. The dev server sees `Host`/`Origin` as `localhost:<port>` so Vite's and Next's allowed-host checks pass; no path prefix, so absolute asset paths work. Tickets live in memory only — a host restart ends every preview. Funnel never; the door is exactly as reachable as the host's own address. In-app only: no Safari hand-off (a decision, 2026-09-02 — the credential stays in the app).
- Host contract: `protocol/README.md` → `/api/preview/door`, `/api/preview/candidates`, `POST /api/preview`, `/api/preview/{id}/keepalive`, `DELETE /api/preview/{id}`, `/api/preview/stop`. Discovery never offers the host's own ports. `TAVI_PREVIEW_PORT` (8788) / `TAVI_PREVIEW_DOOR_PORT` (8443).

### 7.12 Source control: worktrees, changes, commits, pull requests (design approved 2026-09-02; the Orca bar)

The bar is Orca's mobile git integration — matched, then beaten (owner, 2026-09-02; `ROADMAP.md`, `ORCA_SOURCE_CONTROL_RESEARCH.md`). The approved design is the canvas https://claude.ai/code/artifact/cf3e1af2-90ab-4c5b-9cec-5a68969538e7 (sources in `docs/assets/source-control-canvas/`). What it fixes:

- **Home: one card per folder, worktrees inside it** (owner pick over "worktree is the card" and "branch on the agent row"). Inside the card each worktree is a raised glass group — a hair lighter than the card, a 1px inner top highlight, 8px corners, 6px of air between groups, **no hairlines inside the card** (iOS 26 separates grouped content with material, not strokes; the only hairline is under the folder title). A worktree group reads: branch glyph, branch name (15 semibold, truncating), beneath it `↑ahead ↓behind · N uncommitted` and `PR #n` when one exists (13 secondary), chevron → Source Control; its agents indented beneath as today's rows (34px glyph tile, primary line, kind, status, freshness). The last row of the card is **New worktree**. `Uncommitted` over git's "dirty" (owner call). What beats Orca is on this row: Orca's mobile list is git-blind (branch and PR only).
- **New worktree** is the third answer to *where* in the New Agent sheet: Computer, Agent, then Where = a folder | a new worktree; Repository (pre-filled from the card), Start from (the repo's default branch, `origin/HEAD` → `main` → `master`, changeable), Branch (typed, or named from a GitHub issue). A sentence above the one button says exactly what will happen — folder, branch, base, that ignored setup files such as `.env` are copied, and that the agent opens there. Create = `git worktree add --no-track -b <branch> <path> <base>` with `push.autoSetupRemote` and `branch.<b>.base` set, then #67's open-on-create. Guardrails as #24: inside the roots freely, outside with the `outsideRoots` confirmation.
- **Source Control**, one worktree, three tabs, **one job and one primary action each**: *Changes* (files with a stage checkbox and `+n −n`, "Stage all", a commit box pinned at the bottom with one button and "Let Claude write it"); *Pull request* (empty state says what creating will do — push first — one button, "Link an existing one"; created through the person's own `gh` login, and said plainly when `gh` is missing); *Commits* (ahead of main with Push; behind main with Pull main in). Every tab's header carries the branch's `↑↓ vs main` and the agent's status — the join Orca lacks. Updates while open. **Remove** lives behind the header's `···`.
- **Remove** names what would be lost — uncommitted changes with `+n −n`, unpushed commits, whether an agent is still working there — and offers the safe path first (push, then remove); discard is spelled out with counts; amber only on the safe action. Never a silent `--force`. Removal = rename the checkout aside, deregister (`worktree prune`), delete in the background; the branch is deleted only on live proof its commits exist elsewhere — merged into the base, or pushed by that very removal — or when the person confirmed the exact commit count away (Discard); else kept and said. With uncommitted changes there is no safe path, so nothing is amber. A locked worktree is refused.
- Design rules that made the cut, to keep while building: one job per screen; one amber action per screen; no card inside a card; type 17 / 15 / 13 / 12 — 17 a sheet's title, 15 a row's primary line, 13 a sentence, 12 a label (section labels in small caps, kind lines, status words; owner call 2026-09-03: 12, not 13 — the count beside a label is the loud part, the label is not), with 11px monospace only for a folder path and a terminal excerpt; status colours as dots and text, never fills.
- Out of scope, still: merge, rebase, hunk staging, cross-worktree compare.
- Host contract, written into `protocol/README.md` as each part lands: `GET /api/repos` (#59a), `POST /api/worktrees` (#75), `/api/worktrees/{status,stage,unstage,commit,commit-message}` (#77), `/api/worktrees/{log,push,pull-base}` (#78), `/api/worktrees/pull-request` read/create/link + `/api/repos/issues` (#79), `GET /api/worktrees/removal` + `DELETE /api/worktrees` (#81) — all six parts shipped. Removal is two steps: the preview names what would be lost, and the removal must repeat those counts back; the branch goes only when merged, just pushed, or its commit count was confirmed away. Pull requests go through the person's own `gh` login on the computer (Tavi holds no GitHub token); a hand-linked one is remembered as `branch.<b>.tavi-pull-request`; without a title, gh fills it from the commits (one commit → its subject, several → the branch name). *Pull main in* fetches the base's upstream first (best effort, 15 s) and merges today's base — the local branch moved up when nothing stands on it, else its remote-tracking ref; when the fetch cannot happen the local base is merged and the phone says "as of the computer's last fetch" (#83); pushing never forces and never prompts. Removing a worktree names the agents outside it that share a herdr tab with one inside, since herdr closes tabs whole; folders a failed delete leaves behind are swept on host start and hourly and named by `tavi doctor` (#82).

### 7.13 Connection: calm on a bad link (#86, design 2026-09-03; supersedes the mechanics under §7.8)

The everyday case is a phone on a mobile network: 40–120 ms round trips, a path that changes at every tower handover, and blackouts of 5–60 s several times an hour. On 2026-09-02 a home-WiFi version of that turned the app into a sticky "Offline", terminals stuck on "Connecting", and twenty half-open connections at once; three cold reviews agreed the app amplified a link problem it did not cause. The bar: **the app is fine on a link that drops for 30 s several times an hour** — it stays quiet, keeps what it knew on screen, and catches the next good window.

- **One connection pool.** Every HTTP request from the phone goes through one shared `URLSession` (ephemeral, no cache, at most 2 connections per host, keep-alive), so a feature never pays its own TLS handshake and a reconnect is one dial, not six pools racing. The events stream and each open terminal are the only other sockets.
- **One decision-maker per computer.** `AgentDirectory` owns "is this computer reachable": the health probe is single-flight (concurrent askers share the one in flight); the events stream redials at once on a drop (2 → 10 s jittered backoff, reset when a stream that was actually alive ends — frames delivered across 30 s, the host's own pings among them, not merely 30 s passed — or when the app comes to the foreground, never on the first frame; the 8 s handshake budget bounds the TCP connect alone, while the dial as a whole has 15 s from its start — TCP, TLS, the upgrade and the wait for the first agents frame — before it is cycled); the probe runs beside the redial, never in front of it; the repository poll pauses while the stream is down.
- **Offline is earned, not guessed.** "Offline" needs two consecutive failed dials of the events stream *and* two missed probes. One drop is "Reconnecting" with the last state on screen; a frame clears it. A request that takes long shows a stale mark, never a frozen screen. While the phone has no network path of its own, no new "Offline" is earned — a question nobody could ask says nothing about the computer — but an Offline already earned is not masked, and a rejected credential still revokes.
- **A socket is judged by its own heartbeat.** The host pings the events socket every 15 s and drops it after two unanswered pings; the phone's watchdog pings that socket when it has been idle for 20 s and cycles it after 35 s of silence, and a suspended ping send cannot block that deadline. A terminal checks every 10 s, allowing 5 s to send its ping and then a separate 5 s for the matching pong. A pong received before the send continuation resumes also proves liveness. A satisfied path change checks an established connection at once — one challenge whose ping carries a payload the answering pong must echo, on a single 2 s budget covering send and pong, a miss cycling the socket — and leaves an in-progress connection its existing budget; an unsatisfied path starts recovery, and a path that comes back cuts the socket waiting on the old one and dials now. Path changes never reset backoff.
- **Terminal retries have one owner (#107).** A terminal has a 12 s overall ready deadline, with a 10 s TCP connection budget. Retries back off from 250 ms to 8 s with jitter and reset after 30 s continuously connected, or an explicit foreground restart. A ready message received during the retry delay cancels that retry. Before closing an old socket to redial, the controller invalidates its generation so old receive/send completions cannot schedule another retry or mutate the replacement. Cancellation also releases the retry handle: a cancelled task never counts as a pending retry. When the phone moves between interfaces with both networks up, the terminal does not tear its socket down: it asks. The liveness round already in flight becomes that question, on a single two-second deadline measured from the moment the path changed and covering both the ping leaving the phone and the computer's answer; a round already closer to its own deadline keeps it — the check may only shorten a budget, never lengthen one — and a handover that flaps repeatedly is still one question. An answer inside the deadline keeps the connection and the log says `handoverChecked`; silence says `handoverFailed` with `handover-pong-missing` or `handover-send-stalled`, the same names the events link uses, and the terminal reconnects, resuming where it was (#111). A scroll never delays a heartbeat: the terminal's ping leaves ahead of queued input, and wheel reports travel as one frame per turn — the only input Tavi will drop, and only the oldest of them, and only when the link is already behind (#111).
- **Recovery does not multiply background work.** Repository refresh has one serial polling task per computer, spaced 24–36 s apart and paused while its events connection is stale or revoked. Terminal retries do not trigger repository or preview fetches. Home excerpts remain snapshot-driven, with a 2 s debounce and serial requests for active/needs-you cards; a newer snapshot cancels the prior round. Existing requests retain their HTTP deadlines. A terminal-only outage does not suspend a healthy computer’s home feed, but adds no extra Git or excerpt retries.
- **The true words.** The host reports the caller's path from the computer's own Tailscale (`GET /api/host` → `connection: {path: direct | relay | unknown, relay?}`), and the phone says it: "Live · 7 ms" stays; a relayed path reads "Live · 40 ms · relay"; the computer sheet's *Right now* row spells it out ("Direct on your network", "Through a Tailscale relay (blr) — slower, still private", "Reaching this computer, path unknown"). "Isn't answering" appears only for an earned Offline. Latency is a fact, never coloured as a problem.
- **Polls behave.** The Source Control sheet polls every 5 s while it is open, backs off to 15 s after a failure, and its reads time out at 20 s (writes keep 90 s). The Files sheet checks mentioned paths at most four at a time.
- **Release check:** WiFi off, cellular only, twenty minutes of real use; no stall longer than a few seconds, no "Offline" while the Mac is up. Never install wirelessly on a test phone.
- What it will not do: make a dead link work. With no path for a minute the app waits it out with the last state on screen and says "Reconnecting".

### 7.14 Attach an image from the composer (#88, 2026-09-03)

"Show the agent what I mean": a paperclip on the composer opens the photo library; the picked image is shrunk on the phone (longest side 2048 px, JPEG) and uploaded to the agent's own folder under `.tavi/uploads/`, and its path is appended to the message, since Claude Code and friends read an image when the prompt names one. The composer says where it went ("Saved on MacBook Air in the project's .tavi/uploads folder") the first time; the host keeps the folder out of git and sweeps it after a week. Images only, inside the roots, 10 MB at most (§7.9). Camera and paste come later.

### 7.15 Design pass close-out (#54 with #52, 2026-09-03)

The audit, the P1/P2 pass, and the direction correction (pure graphite, one amber) are on the issue; `TaviTheme.swift` is the one source of colour, radius, and a spacing scale for insets (inline gaps stay literal). What the close-out fixed and keeps:

- **Section labels** are 12 pt small caps with wide tracking, one `SectionHeader` on the home and in every sheet; its trailing slot holds a section's one quiet action (Stage all, Push, Pull main in) so no sheet re-draws the register by hand.
- **A raised group** (a worktree inside its card) is a hair lighter than the card with a 1 pt highlight along its top edge that fades out down the first 16 pt of its sides — drawn, never a hit target — so the corners stay 1 pt (a flat 1.5 pt slice through the curve thickened them) and a tap at the group's edge reaches the row beneath.
- **The stage checkbox** has three honest states: empty (not staged), a check (staged), a dash (partly staged — some of the file's hunks staged, some not); a tap on the dash stages the rest, as an indeterminate checkbox does everywhere else, and "Stage all" stays offered until every file is fully staged.
- **An idle home** offers its one next step — New agent, amber, the screen's only action — on the idle card, not only behind the toolbar's `+`.
- **Brand** ships under the final name: an app icon in the system's own terms — graphite field, one amber lamp; owner pick 2026-09-03 of three directions: the terminal caret with the block cursor lit amber, a terminal waiting on you (sources and the two alternates in `docs/assets/app-icon/`), and a launch screen in the canvas colour with the app declared dark, so Tavi never flashes white.

Decided against, from #52: dropping a single-agent folder's path line or inlining single-agent projects (a folder name never stands in for a place, and one card per folder is the home's only structure — §7.3); renaming the needs-you row by folder (its primary line is your tab name or the agent's own title, else its folder — §7.3, home v3); an automated test for the running row inside a worktree group (it needs a real Claude turn on the owner's Mac per run; the row is verified by looking, in the audit captures).

## 8. V1.1 candidate scope

- Push notifications from explicit Herdr/provider events.
- Live Activities / Dynamic Island for active or waiting sessions.
- ~~Diff and changed-file viewer.~~ Shipped as §7.10 (read-only).
- Photo/file upload to the active working directory with preview and confirmation.
- ~~File tree plus code/Markdown/image/PDF preview.~~ Shipped as §7.10 (browse is the fallback behind changed/mentioned; no editor).
- Private localhost/dev-server preview.
- Saved quick prompts and commands.
- On-device dictation to the composer.
- Optional direct SSH connection mode.
- Connection diagnostics with Tailscale direct/relay troubleshooting guidance.

## 9. Later scope

- Optional `Terminal | Chat` switch against the same durable session.
- Codex rich adapter via the official local app-server behind the Tavi host protocol.
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
| Needs attention | Explicit approval/question/blocking input is known. | Herdr lifecycle authority, documented provider protocol, explicit Tavi hook. |
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
