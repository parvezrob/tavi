# Tavi connection architecture — research memo v1 (2026-09-09)

Owner's brief: "best in class app that has 99.99 % stability specially with the network … people use rented VPS today to run their agents … A+ connection or nothing at all." This memo is the research and the recommendation, to be reviewed cold by GPT-6 Astra before anything is committed. Sources: five research tracks in `research/0*.md` (products, embeddable transports, relay infrastructure, resumable session protocols, iOS + Tailscale facts), the incident report `docs/history/2026-09-09-tailscale-stall/README.md`, and the repo.

## 0. What "A+" has to mean, in numbers

A network app cannot promise 99.99 % of wall-clock time: the phone's own radio and ISP are outside every SLA on earth (Cloudflare, AWS, Ably all exclude them). What we can promise, and measure, is behaviour **given the phone has any internet at all and the host process is up**:

| SLO | Target | How it is measured |
|---|---|---|
| Reachability | The app reaches the host within 5 s of opening, ≥ 99.99 % of attempts | client counters (opt-in telemetry) + chaos harness |
| Switch recovery | Wi-Fi ↔ LTE, tunnel stall, relay eviction: live screen back within 1 s, ≥ 99.9 % | same |
| Screen | Never blank. Last frame stays with a status over it, always | UI invariant, XCUI test |
| Input | No lost, no duplicated keystroke across any reconnect | sequence numbers + acks, soak test |
| Feel | Typed characters appear ≤ 30 ms regardless of RTT | predictive local echo (Mosh: 70 % of keystrokes instant, 5 ms median vs 503 ms) |
| Honesty | The status names the real condition (host down vs route down vs phone offline) | status model tests |

99.99 % = 4.3 minutes per month. A single relay vendor cannot deliver that alone: Cloudflare had two ~6 h global outages in the last ten months (2025-11-18, 2026-02-20), Fly had a 7 h one in 2024-10. **So the architecture must have two independent routes to every host, and the session must survive switching between them.** That is the whole design in one sentence.

## 1. Why this morning was structural, not bad luck

- The stall is a **known, open Tailscale iOS bug class**: tailscale#19504 (opened 2026-04, active 2026-09-06, "MagicSock ReceiveIPv4 goroutine stops, data plane dies while control plane stays up"), #18889, #15271 (status when failing: `UDP = No`, our exact `udp=false`), #17967, #15776 (clients do not detect DERP loss; keepalives are one-way). Remote-terminal apps are the reporters: SSH/tmux "every 2–3 minutes", Belay Mobile "interactive SSH terminal reliably exposes the failure; toggling Tailscale restores it immediately", mosh/tmux "fails again within 15 min". A third-party root-cause analysis (2026-08-21) explains it: the receive closure dies on ENOTCONN during a socket rebind and nothing restarts it. The extension stays alive and under memory, exactly what our phone log showed.
- **Nothing in Tavi can detect or repair it.** No public API lets one app restart another vendor's VPN. We can only notice that the internet works and the host does not.
- **App Review 4.2.3(i)**: "Your app should work on its own without requiring installation of another app to function." Tailscale-only transport is a review risk on top of a reliability one.
- The owner's premise is right: customers run agents on rented VPSes (public IP, Linux) as often as on a Mac behind home NAT. The design must be equally good for both; today Tailscale is required for both.

## 2. What already exists in the repo (do not rebuild)

- Terminal `tavi.v2`: host keeps the PTY attachment 120 s after the last client, 1 MiB ring with absolute byte offsets and a stream epoch; `?stream=&resume=` replays exactly the missed bytes; `superseded` semantics; 64 KiB frames. This is the Coder/VS Code pattern already built and soak-tested (#111).
- Events `tavi.events.v1`: every frame is a full snapshot, so it is idempotent and self-resuming by construction; host heartbeat 15 s × 2.
- Phone: WebSockets on `NWConnection` (not URLSession, #70), `NWPathMonitor` path observer, reconnect policy, handover pong challenge, 10 s dial budget, honest Offline verdicts (#111 P0–P2).
- Host: pairing QR with fingerprint, per-device credentials, revocation within 2 s, Linux systemd service, macOS launchd, `tavi pair` one-command install.

What is missing: a second route; a session layer that hides route changes (input sequencing, predictive echo, unconditional kept frame); end-to-end encryption independent of the route; status that names a stalled tunnel.

## 3. Options, with what the research says

| Option | Hole punch | Relay | Survives Wi-Fi→LTE | Phone needs VPN? | New deps | Verdict |
|---|---|---|---|---|---|---|
| A. Tailscale VPN only (today) | via Tailscale | DERP | when the extension works | **yes** | none | fails the brief (this morning; 4.2.3(i)) |
| B. Cloudflare Tunnel beside the host | no | Cloudflare edge, 348 cities | reconnect + resume | no | `cloudflared` per host, per-host hostname on our zone | good **prototype**, poor product: TLS terminates at Cloudflare (no E2E without our own crypto anyway), a public hostname per host, connector reconnect bugs, no self-host story |
| C. **Own relay, our protocol, on Cloudflare Workers + Durable Objects** | no | edge; DO created by the host so it sits near the host; hibernating WebSockets; 20:1 message divisor, no egress fee; ≈ $40/month at 10 k users | reconnect + resume (< 1 s with make-before-break) | no | none on the phone (already `NWConnection` WebSockets), one Worker, a Noise handshake on both ends | **primary route** |
| C′. The same relay program on a VPS (Node) | no | Hetzner/Fly/DO in 3–4 regions, host picks lowest RTT (DERP model) | same | no | same code | **second provider** for the 99.99 % math, and the self-host answer |
| D. iroh embedded both ends | yes (disco + QUIC address discovery) | n0 (US/EU/SG free, $199/region dedicated) or self-hosted `iroh-relay` (public IPs, several regions) | **best in class**: one QUIC connection keeps relay + direct paths, switches without a handshake | no | Rust FFI in the iOS app (xcframework, tens of MB before thinning; CoreWLAN link to verify), `@number0/iroh` native addon in the host | **the P2P upgrade, after a spike**: 1.0 is three months old, bindings lagged 13 months pre-1.0, hole-punch rate unpublished; too much to bet the product on today |
| E. TailscaleKit (userspace tailnet inside the app, no VPN profile) | via magicsock | DERP | yes | no, but Tailscale account still required | experimental Swift layer, Go sidecar for Node | later replacement for the VPN in "direct connection" mode; keeps the onboarding wall |
| F. WebRTC data channels + TURN | yes | Cloudflare TURN 1 TB free | ICE restart (slower than QUIC migration) | no | libwebrtc (largest binary of all), `node-datachannel` | dominated by D |
| G. MPTCP / raw QUIC / WebTransport | no | no | partial | no | — | macOS cannot serve MPTCP; Node QUIC experimental; Apple QUIC server blocked. Rejected |
| H. Mosh itself | no | no | UDP roaming | no | C++ | needs a reachable UDP port ⇒ same NAT problem; terminal-only. Borrow its ideas, not the program |

What best-in-class products actually do (Parsec, Jump, Tailscale, RustDesk): P2P hole punching with a relay fallback, **inside the app**, own protocol, E2E. Screens by Edovia is the counterexample: no relay after 15 years, and its reviews say "works at home, never connects remotely". That is where Tavi is today with the VPN removed from the picture.

Why relay-first rather than P2P-first: terminal traffic is 1–5 KB/s, so throughput is irrelevant; latency through a 348-city edge is 20–50 ms to the nearest colo, and predictive echo hides the rest; a relay path is deterministic and testable in the chaos harness; P2P adds a NAT-dependent success rate (libp2p measured 70 %; Tailscale claims > 90 %) that the relay would have to back anyway. P2P becomes an optimisation once the relay and the session layer are proven.

## 4. Recommendation: three layers, two routes

### Layer 1 — Session (protocol, both ends; the part that makes drops invisible)
1. **Terminal**: keep v2 offsets and the ring; raise retention from 120 s to 30 min (the phone may be suspended that long) and the ring to 4 MiB; keep the epoch. Add a **screen snapshot** (serialized emulator state) on a resume miss so a blank screen is impossible even after the ring is overrun.
2. **Input**: client sequence numbers on every input frame, host acks the highest applied; on reconnect the client resends only unacked input; host applies idempotently. Exactly-once across any reconnect.
3. **Predictive echo** (Mosh's design over our stream): host adds an `echoAck` (highest input seq that has been in front of the PTY ≥ 50 ms) to output frames; the phone predicts printable keys in epochs, reveals an epoch on first confirmation, underlines only when SRTT > 50–80 ms. 70 %+ of keystrokes render instantly at any RTT.
4. **Events**: unchanged (snapshots), plus `asOf` already there.
5. **Kept frame invariant**: the terminal surface never clears on a connection state change; only `superseded` or an explicit user action replaces it. (Find out why 07:03 blanked: #119 open question.)
6. **Encryption end to end**: a Noise IK handshake keyed by the pairing (host static key from the QR fingerprint; device static key minted at pairing) inside every route, so the relay, Cloudflare, or a hostile Wi-Fi sees ciphertext only. Route TLS becomes defence in depth.

### Layer 2 — Routes (transport; pluggable, raced)
- A **route** is anything that yields a byte stream to the host: `tailnet` (today's `https://name.ts.net`, optional), `relay` (new), later `direct` (iroh).
- The phone dials **every configured route in parallel** on every connect (Happy Eyeballs style), keeps the first that completes the Noise handshake and delivers a snapshot, keeps one alternate warm with a 15 s ping, and moves to it the moment the active one misses a heartbeat or the path changes (make-before-break on `betterPath`).
- The host advertises its routes in `/api/host` and in the pairing QR (`r=relay-id`), so a phone that paired over Tailscale learns the relay and vice versa.

### Layer 3 — Relay service (ours; small; two deployments)
- Protocol: DERP-shaped and deliberately dumb: the host opens one WebSocket to the relay and authenticates with its public key; a phone opens a WebSocket to `wss://relay/<host-key>`; the relay forwards opaque frames both ways, 64 KiB max, no parsing, no storage. Rate limit per key. ~500 lines.
- Deployment 1: **Cloudflare Workers + Durable Objects** with WebSocket hibernation; the host's connect creates the DO, so it lands in the region nearest the host (Dhaka Mac → apac; Virginia VPS → enam). Cost at 10 k users ≈ $40/month. A deploy evicts DOs: the session layer absorbs it as a < 1 s stutter (test it).
- Deployment 2: **the same relay as a Node program** on two or three VPSes (Hetzner FSN/ASH/SIN or Fly) with the host choosing by RTT. Independent vendor for the 99.99 % math and the self-host answer for privacy-first customers (`TAVI_RELAY=wss://my.box`).
- Route health is measured from the host side too, so the phone's status can say "relay down, direct up" truthfully.

### What Tailscale becomes
Optional "Direct connection" mode for people who already run it: fastest path when the extension works, ignored when it does not. Pairing no longer requires it. Later the VPN could be replaced by TailscaleKit in-process, or by iroh direct paths, without changing Layers 1 and 3.

## 5. Phasing (each phase ships value; nothing waits on P2P)

| Phase | Scope | Exit test |
|---|---|---|
| 0 (this week) | Honest status: public-endpoint probe beside the host probe → `tunnelStalled` + Open Tailscale; kept-frame invariant; `.notice` logs; host log timestamps | reproduce 07:03 with Tailscale toggled off: status names it, screen stays |
| 1 | Relay v1 on Workers+DO + host relay client + phone relay route + route racing; Noise E2E | phone with **no Tailscale** on LTE reaches a Mac behind NAT and a VPS in < 3 s; chaos harness kills the relay mid-session → resume < 1 s |
| 2 | Session layer: input seq/acks, echo-ack + predictive echo, 30 min retention, screen snapshot | Wi-Fi→LTE flip mid-typing: no lost/dup key, no blank, keystrokes visible ≤ 30 ms |
| 3 | Second relay deployment (VPS), host RTT selection, status shows route + provider | Cloudflare down (block its IPs): session continues on VPS relay within 2 s |
| 4 (spike, time-boxed 1 week) | iroh: binary size, LTE CGNAT hole-punch rate from Dhaka to a home Mac and to a VPS, Swift binding stability, multipath switch behaviour | adopt as `direct` route only if it clears: < 15 MB, > 80 % direct, zero crashes in soak |

## 6. Costs and risks, honestly
- **Money**: relay ≈ $40–150/month at 10 k users across both deployments. The expensive part is on-call and the pairing/directory service, not bandwidth (managed realtime services would be $1–9 k/month; ngrok's ToS forbids redistributing its agent).
- **App Review**: 4.2.7 (remote desktop clients) limits *mirrors of specific software* to LAN; Tavi is a generic terminal/agent supervisor for a user-owned computer (a VPS the user rents counts). Word the listing that way; #37.
- **Cloudflare on the path**: E2E makes it blind; the second deployment makes it non-essential.
- **Background**: iOS suspends the app seconds after backgrounding regardless of transport (true today with the VPN too). The session layer's job is the first second after foregrounding; APNs alerts remain the "needs you" path.
- **Not solved by any of this**: the host machine asleep or off. Separate problem (wake-on-LAN, VPS keeps running).

## 7. Open questions for the cold review
1. Is relay-first + iroh-later the right order, or should iroh be primary now?
2. Noise IK keyed by pairing: right choice, or reuse TLS with a per-host CA?
3. DO placement by host: does that hurt a US phone talking to a Singapore VPS more than a phone-near DO would? (Geography says the RTT is the same either way; verify.)
4. 30 min retention × 4 MiB × N sessions on a host: acceptable?
5. What did we miss that Parsec/Jump/Tailscale learned the hard way?
