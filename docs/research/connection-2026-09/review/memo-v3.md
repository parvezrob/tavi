# Tavi connection architecture — the plan (v3, 2026-09-09)

**Status:** research done; v2 reviewed by three cold GPT-6 Astra seats (fresh eyes, networking/iOS, security/ops), all NOT APPROVED with 41 findings between them; v3 folds them (replay table at the end). A confirmation round follows before anything is locked. Owner decides.

Owner's brief: "best in class, 99.99 % stability especially with the network; people run agents on rented VPSes; A+ connection or scrap the project." Evidence base: five research reports in `docs/research/connection-2026-09/` (products, embeddable transports, relay infrastructure, resumable-session protocols, iOS + Tailscale), the incident report `docs/history/2026-09-09-tailscale-stall/README.md`, and the repo.

---

## 0. What "A+" means, in numbers we can actually measure

No app can promise 99.99 % of wall-clock time: the phone's radio and ISP sit outside every SLA (Cloudflare, AWS and Ably all exclude them). What Tavi can promise is behaviour under a stated condition, measured as two separate things, because "attempts that succeed" and "minutes a live session is broken" have different denominators and cannot be converted into each other.

| SLI | Definition | Target | Condition |
|---|---|---|---|
| **Attempt success** | Opening the app, or a terminal, ends with an *authenticated* connection and the *current* state rendered and usable (not merely a socket) within 5 s | ≥ 99.9 % of attempts at launch, ≥ 99.99 % after phase 5 | phone has working internet to at least one relay provider; host process up with working uplink |
| **Session interruption** | Time a foreground session shows anything other than live state, summed per month | ≤ 4 min per 100 session-hours | same |
| **Recovery after a detected fault** | Fault detected → live screen back | ≤ 1 s (P95) when an alternate route is already warm; ≤ 3 s cold | same |
| **Detection of a silent stall** | Peer stops answering with no error → fault detected | ≤ 10 s while a terminal is on screen | — |
| **Path change or explicit close** | Wi-Fi ↔ LTE flip, socket closed by peer, relay eviction | ≤ 1 s to live screen | alternate warm |
| **Screen** | Never blank. The last frame stays, marked stale, with the status over it, until a fresh repaint arrives | invariant | — |
| **Input** | Ordered, duplicate-free delivery across route changes *within one live input session*; when that session's state is lost, the app says delivery is uncertain and asks (today's behaviour), it never replays on its own | invariant | — |
| **Honesty** | Status distinguishes: phone offline · internet reachable but computer unreachable through route X · computer reached but not answering · unknown | invariant | — |

How it is measured: opt-in client counters with the attempt outcome and the route (failed attempts reported when the phone is next online), the chaos harness from #111 extended with route kills, and physical LTE runs. These establish the SLIs per release; a fleet-wide four-nines claim needs fleet-wide data, which does not exist before there is a fleet. Until then the number is a design target, not a marketing claim.

A single relay vendor cannot carry the target: Cloudflare had a ~6 h global outage on 2025-11-18 and a 6 h partial one on 2026-02-20 (about a quarter of BYOIP prefixes, Spectrum down); Fly had a 7 h global one in 2024-10. **Two independently operated routes to every host, and a session that survives moving between them, is the whole design.** Independence is engineered, not assumed: separate providers, separate DNS zones for the two relay endpoints, separate deploy credentials, staggered releases, endpoints cached on both peers at pairing so a cold start with empty DNS caches still has somewhere to go.

## 1. Why this morning was structural

- The stall is a **known, open Tailscale iOS bug class**: tailscale#19504 (opened 2026-04, active 2026-09-06, "MagicSock ReceiveIPv4 goroutine stops, data plane dies while control plane stays up"), #18889, #15271 (status when failing: `UDP = No`, our `udp=false`), #17967, #15776 (clients do not detect DERP loss; keepalives are one-way). The reporters run SSH, tmux and mosh from phones: "every 2–3 minutes", "an interactive terminal reliably exposes it; toggling Tailscale restores connectivity immediately", "fails again within 15 min". A third-party analysis (2026-08-21) gives a mechanism (the receive closure dies on ENOTCONN during a socket rebind and nothing restarts it). Our evidence is consistent with this class; it does not prove that exact mechanism, and the incident report leaves the DERP question open.
- **Tavi can detect failed reachability; it cannot repair another app's VPN.** No public API restarts another vendor's extension.
- **App Review 4.2.3(i)**: "Your app should work on its own without requiring installation of another app to function." A Tailscale-only transport is a review risk on top of a reliability one.
- Customers run agents on rented VPSes (public IP, Linux) as often as on a Mac behind home NAT. Both must be first-class; today Tailscale is required for both.

## 2. What exists today (verified against the code by the review seats)

| Piece | Where | Fact |
|---|---|---|
| Terminal resume | `apps/host/src/attachment.ts:3` | ring 1 MiB, retention 120 s after the host releases the client; offsets are bytes *accepted into the renderer's queue*, not pixels |
| Resume miss | `apps/host/src/terminal-bridge.ts:83` | a fresh attachment; **herdr repaints the whole pane** — an existing screen-recovery path |
| Ownership | `protocol/README.md:433`, `terminal-bridge.ts:183` | every attachment claims immediately; the next one supersedes it, even a compatible resume; the loser stops retrying |
| Frames | `apps/host/src/protocol.ts:4` | 9-byte header + ≤ 65,527 bytes = 64 KiB |
| Events | `herdr-events.ts:118` | full snapshot on subscribe and on every change; `asOf` marks staleness, it is not a sequence number |
| Heartbeats | `socket-heartbeat.ts:4`, `TerminalTiming.swift:16` | events: host ping 15 s, terminate 30–45 s after the last pong; **terminal: phone ping 10 s, 5 s send, 5 s pong, 2 s handover challenge** |
| Dial budget | `ReconnectPolicy.swift:7` | 10 s TCP, 12 s terminal-ready |
| Transport | `NetworkWebSocketTask.swift:78`, `NetworkPathObserver.swift:20` | `NWConnection` WebSockets; the path observer reports default-path satisfaction and the first interface, not host reachability |
| Identity | `pairing.ts:74`, `HostPairing.swift:68` | **the host identity is 32 random secret bytes; the fingerprint is the first 16 hex chars of SHA-256 over them. There is no public key.** Devices hold bearer credentials; the host stores their hashes |
| Revocation | `server.ts:142` | each open socket's bearer credential is rechecked every 2 s against the registry |
| Host TLS | — | none; `tailscale serve` terminates TLS. The host speaks plain HTTP on 127.0.0.1:8787 |
| Surfaces beyond the terminal | `server.ts:281` | pairing, host info, agents, files, source control, uploads, previews (a second loopback "door" published by Serve, opened in `WKWebView`), plus an HTTPS probe the terminal client uses to classify handshake rejections |
| Local composer | `TerminalComposer.swift` | the phone already has a local text field, so typed text has immediate local feedback before it is sent |

What is missing: a second route that carries **the whole surface**, not just the terminal; a real cryptographic host identity; a session layer that makes moving between routes invisible; status that says what is known and no more.

## 3. Options, and what the field does

| Option | Hole punch | Relay | Survives Wi-Fi→LTE | Phone needs VPN? | New deps | Verdict |
|---|---|---|---|---|---|---|
| A. Tailscale VPN only (today) | via Tailscale | DERP | when the extension works | **yes** | none | fails the brief |
| B. Cloudflare Tunnel beside the host | no | edge | reconnect + resume | no | `cloudflared`, per-host hostname on our zone | prototype only: TLS ends at Cloudflare (bearer credentials in upgrade headers would be visible there), no self-host story, WebSockets cut on Cloudflare deploys, cloudflared #1652 (open) drops the WebSocket upgrade header on its default transport and the HTTP/2 workaround was later retracted |
| C. **Own dumb relay + end-to-end TLS inside it**, on Cloudflare Workers/Durable Objects | no | edge, DO keyed by host identity | reconnect + resume | no | one Worker; a loopback adapter on the phone; TLS on the host | **primary route for customers** |
| C′. The same relay as a Node program on 2–3 VPSes | no | Hetzner/Fly/DO regions | same | no | same code | **second provider**; the self-host answer |
| D. **Direct pinned TLS to a public host** (VPS with a public IP, or a Mac with a forwarded port) | n/a | none | reconnect + resume | no | host TLS (same as C) | **route for VPS customers**: fastest, no third party; the relay stays as the fallback |
| E. iroh embedded both ends | yes | n0 or self-hosted | **best of all**: one QUIC connection holds relay + direct paths | no | Rust FFI in the app (xcframework 44 MB before thinning), native addon in the host | **the P2P upgrade, gated by a spike run early** (§5) |
| F. TailscaleKit in-process | via magicsock | DERP | yes | no, but a Tailscale account still required | experimental Swift layer | later replacement for the VPN in "Tailscale mode" |
| G. WebRTC + TURN | yes | Cloudflare TURN | ICE restart | no | libwebrtc (largest binary) | dominated by E |
| H. MPTCP / raw QUIC / WebTransport | no | no | partial | no | — | macOS cannot serve MPTCP; Node QUIC experimental; Apple QUIC server blocked. Rejected |
| I. Mosh itself | no | no | UDP roaming | no | C++ | needs a reachable UDP port: same NAT problem. Borrow its ideas |

What the field does (`01-product-survey.md`): **every coding-agent product** (Claude Code Remote Control, Codex Remote, Cursor self-hosted machines, VS Code Tunnels, Happy Coder, Omnara) uses one long-lived outbound connection to a vendor relay and none hole-punches; only Happy Coder and VS Code Tunnels keep end-to-end encryption. Remote-desktop products hole-punch because video needs UDP throughput, and the ones with no relay (Parsec on CGNAT, Moonlight, Screens) have the worst "works at home, fails remotely" reputations; RustDesk merged WebRTC on 2026-09-05 for exactly that reason. Roaming without re-authentication exists in four designs: Mosh, WireGuard, QUIC, Chrome Remote Desktop's ICE restart. Heartbeats converge on 3–5 s. Control planes are the outages customers see as "your machine is offline" (Jump 24 h, Happy ~20 h, Funnel silently dead while reporting healthy). On iOS every terminal vendor keeps the process alive with Location "Always" or accepts 20–30 s of background; Blink serializes mosh's state and rehydrates it.

**Why relay-first and not iroh-first.** The strongest case for iroh: it already has authenticated encryption, hole punching, relay fallback and multipath migration, and the alternative is an unwritten transport system. The case against betting on it today: 1.0 is three months old, its Node binding lagged 13 months before 1.0, its iOS build has an unverified `CoreWLAN` link and unmeasured size, its hole-punch rate on LTE CGNAT is unpublished, and its free relays are rate-limited with no guarantees. So the spike runs **early** (phase 2, not last) with pass/fail gates, and the architecture is shaped so that iroh, if it passes, slots in as a route without changing the session layer. A terminal at 1–5 KB/s does not need P2P for bandwidth; it needs a relay close to both ends, fast detection, and a session that survives the switch.

**Why end-to-end TLS inside the relay, not a new Noise protocol.** The app's whole surface is HTTP + WebSockets. If the relay is a dumb byte pipe and the *host itself* terminates TLS 1.3 with a key the phone pinned at pairing, then every existing route (`/api/*`, both WebSockets, uploads, the preview door) works unchanged through the relay, the bearer credential stays inside the encrypted channel, revocation keeps working exactly as today, and the relay operator sees ciphertext. This is the Tailscale Funnel model, which the survey found to be the only hosted design where the provider cannot read traffic. A Noise design would have to re-carry all of that surface itself, and its 65,535-byte record limit is already smaller than one Tavi frame. Noise stays as the fallback if the TLS-through-pipe adapter fails its spike.

## 4. The design: three layers, several routes

### Layer 1 — Identity and trust (prerequisite for everything else)
1. **Host key pair.** The host generates an Ed25519 (or P-256) key pair; the existing random identity becomes the seed so the *displayed fingerprint stays the same* where possible, or a versioned identity file replaces it. The host serves TLS 1.3 itself with a self-signed certificate for that key. The fingerprint shown on both screens is derived from the public key.
2. **Pairing v2** (`tavi://pair?v=2&…`): the QR carries the full host public key, the host's relay endpoints for both providers, and the single-use secret. The phone verifies the fingerprint it shows against that key and *pins the key*. The pairing exchange happens inside a TLS session pinned to it (over Tailscale, LAN, direct or relay). The phone also generates a device key pair; the host records its public key beside the bearer credential.
3. **Device admission to the relay.** At pairing (and refreshed inside the channel) the host issues the phone a short-lived, signed **admission capability** bound to the device id. The relay verifies it before allocating anything. A host registers with the relay by signing a fresh relay challenge with its key (proof of possession, not just presenting a key).
4. **Revocation and rotation.** The host's device registry stays the single authority; every inner session, on every route, active or standby, is bound to a device record and rechecked as today. Revocation cuts every route, rejects queued input, and invalidates admission capabilities (the relay only ever holds short-lived ones). Host key rotation is a re-pair; a host-key mismatch stops automatic connection and never falls back to a weaker route.
5. **Migration.** Existing phones learn the host public key over their current authenticated Tailscale connection once, then behave as v2 pairs. Never from a relay.

### Layer 2 — Session (what makes route changes invisible)
1. **Transport ≠ attachment.** A route is *established* (TLS handshake, bearer check, HTTP host probe) without touching any terminal. Terminal ownership is a separate, explicit **activation** on exactly one route, with a host-enforced generation number; late `ready`, input, resize, output and close callbacks from an older generation are rejected. A warm standby never claims or resizes a PTY. Genuine takeover by *another device* keeps today's `superseded` semantics.
2. **Input** within a live input session (device × terminal × ownership epoch): the phone numbers every input frame; the host acks the highest *contiguous* accepted sequence; on route switch the phone resends only unacked frames and the host drops duplicates. Bounded queue, short expiry (seconds, not minutes), and the capability is negotiated, so an older host never sees a resend. When the input session's state is lost (host restart, attachment replaced), the app reports delivery as uncertain and asks, which is what it does today.
3. **Output** keeps v2 offsets and the epoch. Ring and retention are sized by measurement (4 MiB is ~14 min at 5 KiB/s; a burst is shorter) with a **host-wide budget** for retained PTYs and bytes, not a per-attachment number picked in a memo. Retention after detach: 10 min default, configurable.
4. **Kept frame.** The terminal surface never clears on a connection-state change. On a resume miss the existing herdr repaint is used, with the stale frame visible until the repaint has actually arrived (`ready` alone does not prove a complete repaint; the surface waits for the first output after `ready` or a short timeout). No new emulator is introduced. Why 07:03 blanked is found and fixed first.
5. **Events**: full snapshots, unchanged, plus a monotonically increasing snapshot revision so an older snapshot arriving on a losing route cannot overwrite a newer one.
6. **Liveness end to end.** Every liveness check is an authenticated challenge inside the TLS channel, never an outer WebSocket ping (Cloudflare answers those itself without touching the host). Terminal on screen: challenge every 5 s, dead after two misses; the events stream keeps the slower cadence. Detection, promotion, replay and render are budgeted separately (§0).
7. **Route promotion.** All configured routes are dialled in parallel on connect; the first to *establish* wins; one alternate stays established and challenged; the active route is swapped on a missed challenge, a path change (`betterPath`/viability, make-before-break as Apple documents), or an explicit close. Two connections that both ride the disappearing Wi-Fi path will both die; that is the detection budget, not the promotion budget.
8. **Suspension is normal.** The phone keeps a coherent checkpoint *while in the foreground* (epoch, acked offset, geometry, the frame the offset corresponds to); the background callback only flushes it. On foreground it shows the cached frame as stale immediately, reconnects asynchronously, and requests a repaint rather than claiming a byte resume if the checkpoint is incoherent. Persisted contents use complete file protection, are excluded from backup, expire, are deleted on unpair, and are shown only behind the app's existing access gate. Raw pending input is *not* persisted across suspension: unacked input older than the expiry is surfaced as "not delivered", not resent.
9. **Predictive echo is a later experiment, not a promise.** Today's local composer already gives immediate feedback for typed text. A Mosh-style overlay (predict printable keys, reveal per epoch on confirmation, never inside the authoritative emulator, disabled in alternate screen, bracketed paste, IME composition and after cursor/mode changes, confirmation markers bound to input sequence + output offset and sent even when there is no output) is measured per application before any number is promised. Coding-agent TUIs redraw arbitrarily; the Mosh figures are Mosh's workload.

### Layer 3 — Routes
| Route | For | Establishes | Notes |
|---|---|---|---|
| `direct` | VPS or any publicly reachable host | TLS to `host:port` pinned to the host key | no third party; dual-stack hostname or literal IP is fine (the app is tested on NAT64 and IPv6-only, App Review 2.5.5) |
| `relay-cf` | everyone | outer WebSocket to the Worker at a deterministic name derived from the host key → inner pinned TLS | DO name is deterministic from the host identity so every ingress finds the same object; the host registers (with proof of possession) **before** any object is created; placement is best-effort and measured, not assumed |
| `relay-vps` | everyone, and self-hosters (`TAVI_RELAY=wss://my.box`) | outer WebSocket to whichever of ≤ 4 relays the host is registered on → inner pinned TLS | rendezvous without a directory: the phone caches all relay endpoints from pairing and tries them in parallel; only the one holding the host's registration answers; the host keeps a registration on **both providers** at all times, so failover needs no discovery |
| `tailnet` | existing Tailscale users | today's `https://name.ts.net` | optional "Tailscale mode"; ignored when it does not answer; a stalled Tailscale exit node can also swallow relay traffic, which the status must be able to name |
| `p2p` (later) | everyone, if the iroh spike passes | iroh connection → inner pinned TLS or iroh's own keys | slots in as a route; nothing above changes |

On the phone the routes are implemented once, as a **loopback adapter**: a local listener the app's existing `URLSession` and `NWConnection` code connects to, which pipes bytes into whichever outer transport is active. TLS runs end to end between the app's networking stack and the host, so pinning is enforced in one place. The feasibility of this adapter is the first spike; if `NWConnection` cannot stack TLS over the WebSocket framer cleanly, the fallback is a custom framer or the Noise design.

### Layer 4 — The relay service (ours, small but not trivial)
- **Protocol**: host registers over one WebSocket per provider with a signed challenge; phones connect with an admission capability naming the host; the relay allocates a **channel** per phone connection and forwards opaque byte frames in order per channel, with per-channel flow control and bounded queues so an upload cannot starve a terminal; when the host leg drops, every channel is closed immediately; a phone learns it from an inner close, not from a relay-supplied WebSocket close alone (a relay close must never permanently disable a route on the phone).
- **Admission before allocation**: pre-authentication rate limits per IP and per host id, handshake deadlines, per-host quotas for admitted phones; an unsolicited connection can never replace a registered host.
- **Hibernation**: authenticated roles, channel maps and generations are reconstructed from WebSocket attachments after a DO hibernates; a deploy still terminates WebSockets, which the session layer absorbs as a reconnect, and rollouts are provider by provider with the other provider verified healthy first.
- **No account database**: the host key is the identity; the only state is live registrations. That is still coordination; it is written down, not declared absent.
- **Deployments**: Cloudflare Workers + Durable Objects with WebSocket hibernation; the same forwarding core as a Node program on two or three VPSes (Hetzner or Fly regions chosen by where customers are; Bangladesh today means Singapore first).
- **Metadata**: the relay sees host identity, phone and host IPs, timing and volume. Not content. Truthful wording for the app and the privacy policy: *"Session content is encrypted between your phone and your computer. Relay operators can observe connection metadata."* A **no-managed-relay mode** (direct and/or Tailscale only, or a self-hosted relay) exists so the PRD's "no mandatory hosted relay" promise survives as a choice; the PRD's default changes and says so.

## 5. Phasing, reordered by the review

| Phase | Scope | Exit test |
|---|---|---|
| **0. Truth and the kept frame** (days) | Status says "Internet reachable; computer unreachable through Tailscale" with the toggle as a troubleshooting step, never a diagnosis; `unknown` exists; the kept-frame invariant; find why 07:03 blanked; recovery logs at `.notice`; host log timestamps | reproduce with Tailscale off and with it stalled: screen stays, status is truthful |
| **1. Spikes** (1 week, parallel) | (a) loopback adapter: pinned TLS through a WebSocket byte pipe on iOS 17–26 with `URLSession` and `NWConnection`; (b) iroh: size after thinning, `CoreWLAN` on iOS, LTE CGNAT hole-punch rate Dhaka→home Mac and →VPS, Wi-Fi→LTE with UDP blocked, provider failure, suspension; (c) DO placement and duration cost with hibernation under our message pattern | written results with numbers; iroh adopted as a route only if < 15 MB, > 80 % direct on LTE, zero crashes in soak, relay-only works with UDP blocked |
| **2. Identity** | host key pair + host TLS; pairing v2; device keys; admission capabilities; migration of existing pairs | pair a phone with no Tailscale over LAN and over `direct`; revoke; rotate |
| **3. One complete route** | relay-cf (or `direct` for a VPS) carrying the *entire* surface; route establishment separate from attachment; activation with generations | with Tailscale absent on LTE: pair, list agents, open a terminal, run a Files action, open a preview |
| **4. Promotion and the second provider** | warm standby, authenticated 5 s challenges, promotion on miss/path change/close; relay-vps; host registered on both; endpoints cached at pairing | kill Cloudflare (block its IPs, cold DNS): live within 2 s on relay-vps; kill relay-vps: same the other way; Wi-Fi→LTE mid-typing: live ≤ 1 s |
| **5. Input safety and retention** | numbered input with contiguous acks; negotiated; host-wide retention budget; snapshot revisions | soak with route kills: zero lost, zero duplicated MARKs across 1,000 switches |
| **6. Suspension** | foreground checkpoint, protected storage, stale-frame-first resume | background 20 min on LTE, foreground: cached frame in < 100 ms, live in < 2 s |
| **7. Feel** | predictive-echo overlay experiment, per-application measurement | numbers, then a decision |

Phase 0 ships this week regardless. Phases 1–4 are the product change. Tailscale is optional from phase 3.

## 6. Costs, risks, and what stays unsolved

- **Money**: Cloudflare Workers + DO at the modelled workload (2,000 concurrent sessions, 2 h/day) ≈ **$39/month** *if* hibernation removes idle duration; if timers or our socket handling defeat hibernation, duration alone could be ~$700/month. VPS relays: $30–100/month compute plus egress that depends heavily on region (India is 6× the US rate on Fly). Both figures are estimates pending phase 1(c) measurement. Managed realtime services would be $1–9 k/month; ngrok's terms forbid redistributing its agent.
- **Operations before 10 k users**: a named on-call owner, external end-to-end probes on both providers, certificate-expiry and billing alarms, abuse response, runbooks, provider-by-provider rollouts, capacity for one provider carrying everything, and a reconnect-storm test.
- **App Review**: 4.2.3(i) is a real risk of the current design and this plan removes it. 4.2.7 (remote desktop clients) is **unresolved**: whether a rented VPS counts as a user-owned computer and whether agent supervision makes Tavi a "mirror of specific software" is Apple's call. Positioning: *"a general-purpose remote terminal for computers you control, including your own Mac and Linux servers you provision"*, with arbitrary shell use demonstrable beside the agent features, an isolated reviewer host, and the question raised with App Review early (#37). Wording does not change what ships.
- **Privacy**: the relay sees metadata; the PRD's "no mandatory hosted relay" becomes "relay by default, never mandatory". That reversal is the owner's decision to make explicitly.
- **Background**: iOS suspends the app 20–30 s after backgrounding whatever the transport; that is true today with the VPN too. Live Activities can show status, they do not keep a socket alive. Location "Always" is not acceptable for Tavi.
- **Not solved by any of this**: the host asleep or off; the host's own uplink down; a wedged herdr. Those are host-side problems with host-side answers (wake-on-LAN, VPS, the host watchdog).

## 7. Replay table — v2 review findings and where v3 folds them

| # | Seat(s) | Finding | Disposition |
|---|---|---|---|
| 1 | all three | BLOCKER: fingerprint is a truncated hash of random bytes, not a public key; Noise IK cannot bootstrap from it | **adopt** → Layer 1: host key pair, pairing v2 carrying the full key, device keys, migration over the existing authenticated route |
| 2 | all three | BLOCKER: route racing conflicts with immediate attachment ownership; a slower candidate supersedes the winner | **adopt** → Layer 2.1: establishment ≠ activation; generation fencing; standby never claims |
| 3 | all three | BLOCKER: "exactly-once" exceeds the mechanism (PTY write and ack ledger are not atomic; scope undefined) | **adopt** → Layer 2.2: guarantee scoped to a live input session; contiguous acks; negotiated; uncertainty reported when state is lost |
| 4 | seat 3 | BLOCKER: relay addressing used as admission; key presentation is not proof; unlimited keys evade limits | **adopt** → Layer 1.3, Layer 4: proof of possession, host-issued admission capabilities, admission before allocation |
| 5 | seats 2, 3 | BLOCKER: E2E boundary unspecified; bearer credential travels in the outer upgrade header; HTTP surface, uploads, preview door uncovered | **adopt, redesigned** → inner pinned TLS through a dumb pipe carries the whole existing surface; credential stays inside; Noise demoted to fallback |
| 6 | seats 1, 3 | HIGH: SLO mixes attempt rate with time; independence assumed; "any internet" too loose | **adopt** → §0 rewritten: separate SLIs, conditions, engineered independence, no fleet claim before a fleet |
| 7 | all three | HIGH: 10 s detection contradicts 1 s recovery; outer WS pong proves only the relay | **adopt** → §0 separate budgets; Layer 2.6 authenticated inner challenges; 1 s applies after detection or on path change/close |
| 8 | seats 1, 2 | HIGH: one host socket cannot carry phones, terminals, events, HTTP; relay ≠ 500 lines | **adopt** → Layer 4 channels, flow control, fencing, hibernation reconstruction; line count removed |
| 9 | seats 2, 3 | HIGH: "no control plane" leaves rendezvous unresolved across VPS relays and providers | **adopt** → host registered on both providers always; endpoints cached at pairing; parallel try of ≤ 4 relays; deterministic DO name; "coordination written down, not declared absent" |
| 10 | seats 1, 2 | HIGH: predictive echo promoted from heuristic to guarantee; herdr PTY indirection; no-output ack case; TUI/alt-screen/IME | **adopt** → Layer 2.9 demoted to a measured overlay experiment in phase 7; composer echo named as what exists |
| 11 | seats 1, 2 | HIGH: "serialized emulator state" does not exist and would duplicate herdr's repaint; offset beside an older frame skips output | **adopt** → Layer 2.4 uses the existing repaint with stale-frame-first; no new emulator; 2.8 coherent foreground checkpoint |
| 12 | seats 2, 3 | HIGH: background snapshot not durable; persisted input is a secret store; stale input replay | **adopt** → Layer 2.8: foreground checkpoint, protected storage, no persisted raw input, expiry, access gate |
| 13 | seat 1 | HIGH: phases bundle projects and reverse dependencies | **adopt** → §5 reordered: truth → spikes → identity → one route → promotion + second provider → input → suspension → feel |
| 14 | all three | HIGH: `tunnelStalled` asserts a cause the probe cannot establish | **adopt** → phase 0 wording "Internet reachable; computer unreachable through Tailscale", `unknown` state, toggle as troubleshooting |
| 15 | seat 3 | HIGH: revocation and rotation across a multiplexed relay socket | **adopt** → Layer 1.4: registry stays authoritative; every inner session bound to a device record; capabilities short-lived |
| 16 | seat 3 | HIGH: DO eviction, rollouts, on-call, monitoring missing | **adopt** → Layer 4 and §6 operations list |
| 17 | seat 3 | HIGH: E2E does not make the relay "blind"; PRD reversal not argued | **adopt** → Layer 4 metadata wording; no-managed-relay mode; owner decision named |
| 18 | seats 1, 3 | HIGH/MEDIUM: rented-VPS 4.2.7 exemption asserted without support | **adopt** → §6 marks it unresolved; positioning and early review contact |
| 19 | seats 1, 3 | MEDIUM: costs overstated/unqualified; Fly bandwidth; DO duration if hibernation fails | **adopt** → §6 both cases stated as estimates |
| 20 | seat 2 | MEDIUM: Noise 65,535-byte record < 64 KiB frame | **moot** with inner TLS; noted for the Noise fallback |
| 21 | seat 2 | MEDIUM: 4 MiB ≈ 14 min; host-wide limits; geometry after the 8 s detach grace | **adopt** → Layer 2.3 measured sizing and host-wide budget |
| 22 | seat 2 | MEDIUM: dual-stack claim; A-only works via DNS64; test NAT64 | **adopt** → Layer 3 `direct` row |
| 23 | seat 1 | MEDIUM: Feb 2026 outage scope; DO placement best-effort; "348 cities" ≠ end-to-end latency | **adopt** → §0, Layer 3 |
| 24 | seat 1 | Cloudflare Tunnel deserves a fairer hearing; direct TLS to a VPS is its own route | **adopt** → §3 B reworded with the retracted workaround; new route `direct` (D) |
| 25 | seat 1 | iroh spike should precede the transport commitment | **adopt** → phase 1(b); adoption gates written |
| 26 | seat 1 | Live Activities are not a background-socket mechanism | **adopt** → §6 |
| 27 | seat 2 | Tailscale exit node / tailnet DNS can capture relay traffic | **adopt** → Layer 3 `tailnet` row |
