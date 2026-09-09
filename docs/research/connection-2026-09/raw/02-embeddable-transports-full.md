<!-- verbatim final report of the research agent, 2026-09-09; condensed version in ../02-embeddable-transports.md -->

Research complete across all nine areas. Here is the report.

---

# Transport options to replace phone-side Tailscale for Tavi

Scope: an iOS app (Swift) and a Node.js host on a Mac behind NAT or a Linux VPS, needing a NAT-traversing, relay-backed, end-to-end-encrypted byte stream **without a NetworkExtension on the phone**. Facts are sourced; judgements are marked *[inference]*.

---

## 1. iroh (n0-computer, Rust)

**Maturity.** 1.0.0 shipped **2026-06-15** ([blog](https://www.iroh.computer/blog/v1)); crates.io at **1.1.0, 2026-08-26** ([docs.rs/iroh](https://docs.rs/iroh)). 1.x guarantees wire compatibility across all v1 endpoints and language bindings. The last wire-breaking change was v0.96 (2026-01-27). 12.5k stars. Dual MIT/Apache-2.0.

**Architecture.** "Dial keys, not IPs": a node is an Ed25519 public key (`EndpointId`). Transport is QUIC + TLS 1.3, always end-to-end encrypted, including through relays — relays forward ciphertext addressed by EndpointId and cannot decrypt ([FAQ](https://docs.iroh.computer/about/faq)). Notably, iroh **replaced Quinn with `noq`**, n0's own QUIC implementation, at v0.96, because Quinn gave no visibility into path/relay switching ([noq announcement](https://www.iroh.computer/blog/noq-announcement)). NAT traversal is magicsock-lineage (explicitly "heavily inspired by Tailscale's WireGuard connection engine") but hole punching now runs *inside* the QUIC connection via the IETF QUIC-NAT-Traversal draft, and address discovery moved from STUN to **QUIC Address Discovery** ([QAD post](https://www.iroh.computer/blog/qad)). No evidence of UPnP/NAT-PMP/PCP port mapping — absence of evidence, not a confirmed "no".

**Connection migration.** Yes, and this is its strongest claim. v0.96 shipped native **QUIC multipath**: one connection holds several simultaneous paths (IPv4/IPv6 × Wi-Fi/cellular) and hot-swaps to the best one on network change without dropping ([0.96.0 blog](https://www.iroh.computer/blog/iroh-0-96-0-the-quic-multipaths-to-1-0)). Caveat with a source: [issue #3979](https://github.com/n0-computer/iroh/issues/3979) — "when switching from 5G to Wi-Fi iroh does not switch from relay to direct connection" — hole punching was not re-triggered on network change and exhausted path slots were never reclaimed. Fixed in **v0.98**. The 0.96 release notes themselves listed "holepunching is not re-triggered when your network conditions change" as a known issue. So the failure mode during that window was *stays on relay*, not *loses the connection*.

**Relays.** `iroh-relay` is the same crate n0 runs in production, open source, self-hostable. Public relays in **US, EU, Singapore**; home relay chosen by latency (stated in architecture terms; the exact algorithm is not documented to Tailscale-DERP detail). Pricing ([iroh.computer/pricing](https://www.iroh.computer/pricing)): Community $0 — public relays, rate-limited, unauthenticated, **no uptime or performance guarantee**; Pro **$19/mo** — authenticated shared relays, 10k concurrent connections, 5 MB/s, 100 GB egress then **$0.09/GB**; Dedicated **$199/mo per region** — 60k connections, no rate limit, 250 GB egress.

**iOS.** `iroh-ffi` generates Swift bindings via uniffi and ships a **prebuilt xcframework via SwiftPM** (`IrohLib`) — no Rust toolchain needed to consume. Needs `-framework Network` in linker flags. **No NetworkExtension entitlement** — plain UDP sockets. Bindings mirror the stable 1.0 surface; blobs/docs/gossip are explicitly out of scope. Size: a third-party integration ([cmux DESIGN.md](https://github.com/manaflow-ai/cmux/blob/main/plans/feat-ios-iroh/DESIGN.md)) measured a ~15 MB staticlib and **+7.7 MB per arch slice** after dead-stripping — one measurement, not an n0 number. That same doc closes the endpoint on background and rebinds on foreground (sub-second reconnect); n0 publish nothing about iOS background behaviour. *[inference: iroh gives you no background persistence that plain sockets don't.]*

**Node.js.** `@number0/iroh` **1.0.0**, published ~Aug 2026, napi-rs, Node ≥20.3, prebuilt for darwin-arm64, linux x64/arm64 (glibc + musl), Windows, Android. It exposes **raw QUIC streams** (`openBi`/`acceptBi`), not just the high-level protocols ([JS docs](https://docs.iroh.computer/languages/javascript)). No darwin-x64 prebuild listed.

**Users.** Delta Chat, Prime Intellect, Psyche, Tandemn ([awesome-iroh](https://github.com/n0-computer/awesome-iroh)). n0, inc. is founder-backed; no public funding round found.

---

## 2. libp2p

**rust-libp2p** has mature QUIC and **DCUtR** hole punching ([spec](https://github.com/libp2p/specs/blob/master/relay/DCUtR.md)): peers sync over a circuit-relay-v2 connection then simultaneous-open; "works well for UDP, reasonably well for TCP… apart from not working all the time," 3 attempts before giving up. Requires **AutoNAT + Identify + a relay you can reach**; the spec's own caveat is symmetric NAT ([IPFS blog](https://blog.ipfs.tech/2022-01-20-libp2p-hole-punching/)). No public relay fleet is offered as a product — you run your own.

**swift-libp2p** is the blocker. Its README says **"‼️ This is a work in progress ‼️"** and advises against use outside experimental projects until 1.0. Implemented: TCP, WebSocket, Noise, mplex/yamux, mDNS. **Not started: QUIC, WebRTC, WebTransport, Circuit Relay, and DCUtR** ([repo](https://github.com/swift-libp2p/swift-libp2p)). MIT, Breth Inc., 208 commits. So the two features Tavi needs are the two that do not exist. The only iOS path is rust-libp2p through FFI, which you would have to build and maintain yourself — no published Swift package equivalent to `IrohLib`.

*[inference: libp2p is iroh's problem space with more ceremony (peer routing, DHT, multiaddr, protocol negotiation) and no turnkey iOS story. It is strictly worse for this use case than iroh.]*

---

## 3. WebRTC data channels

**iOS.** The official `GoogleWebRTC` pod is **deprecated**, last version 1.1.32000 (March 2023) ([cocoapods.org](https://cocoapods.org/pods/GoogleWebRTC)); Google stopped publishing iOS binaries after ~M80. The live options are **stasel/WebRTC** (community SwiftPM/xcframework builds, currently tracking Chromium M152, iOS 12+, active) and **webrtc-sdk/Specs** (LiveKit's fork). No NetworkExtension needed. No maintained pure-Swift ICE/DTLS/SCTP stack exists. Binary size figures are wildly configuration-dependent; no authoritative current number found *[inference: 15–40 MB per arm64 slice is the anecdotal range]*.

**Node.** `node-datachannel` **0.33.3**, MPL-2.0, N-API, prebuilt for macOS x64/arm64, Linux x64/arm64 glibc+musl, Windows — data channels only, no media ([npm](https://www.npmjs.com/package/node-datachannel)). Wraps libdatachannel (MPL-2.0, active, 3.5k commits). `werift` 0.24.4 is pure TypeScript and full-stack but self-described pre-1.0.

**Traversal and relay.** ICE + STUN + TURN. Industry consensus is **15–30 %** of consumer sessions need TURN, driven mainly by CGNAT on mobile carriers behaving as symmetric NAT ([bloggeek](https://bloggeek.me/webrtcglossary/turn/)). TURN pricing: **Cloudflare Realtime — 1,000 GB/month free, then $0.05/GB** ([docs](https://developers.cloudflare.com/realtime/turn/)); Twilio $0.40–0.80/GB; Metered 500 MB free then plans from $99/mo; coturn self-hosted on a ~$20/mo VPS. TURN relays ciphertext only — DTLS is end-to-end.

**Network switch.** `restartIce()` renegotiates only ICE ufrag/pwd and candidates; **DTLS keys and the SCTP association survive**, so recovery is typically sub-second and cheaper than a fresh PeerConnection. But there are documented non-recovery cases ([Mozilla bug 1552402](https://bugzilla.mozilla.org/show_bug.cgi?id=1552402)). A field measurement of Wi-Fi↔cellular handover showed ~2 s with dual connectivity and STUN pre-validation of the new path. Architecturally this is heavier than QUIC, which migrates on **connection ID** with no renegotiation at all.

**Gotchas.** Safe max message size is **16 KiB**; over Chromium's 256 KiB usrsctp buffer, usrsctp returns EMSGSIZE and **Chromium closes the data channel** ([lgrahl.de](https://lgrahl.de/articles/demystifying-webrtc-dc-size-limit.html)). SCTP has sender-side head-of-line blocking on large messages unless RFC 8260 interleaving is implemented. mDNS candidate obfuscation adds a resolution step on the LAN path. **iOS background: a data-channel-only PeerConnection is suspended when the app backgrounds unless an active audio track keeps it alive** (~40 s otherwise) ([discuss-webrtc](https://groups.google.com/g/discuss-webrtc/c/Zw8S75WjEic)) — the silent-audio-track hack is the known workaround.

---

## 4. QUIC on iOS directly, Node QUIC, WebTransport

**Apple.** `NWProtocolQUIC` exists since iOS 15. Apple publish **no statement about connection migration or multipath** for it; I could not fetch the options list. Server-side is the harder gap: on the WWDC25 Network framework API, `NetworkListener.run` requires `OneToOneProtocol` and **QUIC conforms to `MultiplexProtocol`, with no way to accept an incoming multiplexed connection**; Apple's own forum guidance is to hold off on QUIC with the new API ([forum 791774](https://developer.apple.com/forums/thread/791774), [807135](https://developer.apple.com/forums/thread/807135)). *[inference: NWProtocolQUIC is a client-to-server HTTP/3-shaped tool; it gives you no hole punching and no relay, so it does not solve Tavi's problem on its own.]*

**Rust QUIC in-app.** Quinn supports client address change when `ServerConfig::migration` is true (PATH_CHALLENGE validation, congestion state reset) ([docs.rs/quinn](https://docs.rs/quinn/latest/quinn/)), but there are no worked examples of multi-socket endpoints. iroh's team judged Quinn insufficient for path/relay switching and wrote `noq` instead.

**Node.** `node:quic` is still **experimental behind `--experimental-quic`**, present since v23.8.0, first real implementation targeted at Node 25 (Oct 2025). Not something to build a product on today. `@fails-components/webtransport` is at **1.5.3, published ~Aug 2026**, actively maintained, but its own README calls it "a ducttape style solution until… native support" is in Node.

**WebTransport on iOS.** **Safari 26.4 (March 2026) shipped WebTransport on macOS and iOS**, making it Baseline ([WebKit](https://webkit.org/blog/17862/webkit-features-for-safari-26-4/)). That is the web API only — no native Swift WebTransport client found, and WebTransport is client→server, so it offers **no NAT traversal to a home Mac**.

---

## 5. Multipath TCP on iOS

`URLSessionConfiguration.multipathServiceType` offers `.handover` ("seamless handover between Wi-Fi and cellular in order to preserve the connection"), `.interactive`, `.aggregate`. Per [mptcp.dev/macOS](https://www.mptcp.dev/macOS.html): **only `.aggregate` needs the `com.apple.developer.networking.multipath` entitlement**; the other modes need no extra steps. But the same page states **"on macOS, MPTCP is only supported for the client side"** — so a Mac host cannot terminate MPTCP, which kills the home-Mac case outright. Linux has mainline MPTCP since kernel 5.6, so a VPS could serve it. URLSession MPTCP is iOS-only (not settable on macOS).

Unresolved from primary sources: whether `URLSessionWebSocketTask` honours the multipath service type, and Apple/Linux v0-vs-v1 interop. *[inference: even if it worked, MPTCP gives handover only — no NAT traversal — so it could at best harden a VPS route, never a home-Mac route.]*

---

## 6. Tailscale as a library — and the iOS stall bug class

**The stall.** The bug class is real and long-lived, though I could not pin an issue matching the exact 2026-09-09 symptom (the label search returned no results, and the web-search budget ran out). Documented anchors: iOS Network Extensions get **15 MB on iOS 14 and earlier, 50 MB on iOS 15+**, enforced by jetsam; Brad Fitzpatrick publicly described the ~15 MB budget as the reason Tailscale logs remaining memory on every log line ([tweet](https://x.com/bradfitz/status/1247034492688068608)). [#2566](https://github.com/tailscale/tailscale/issues/2566) "iOS Network Extension crashes with Tailscale 1.12.1" — believed memory-related. [#19810](https://github.com/tailscale/tailscale/issues/19810) — extension failed to start under exit-node load on 1.98.2. [#15186](https://github.com/tailscale/tailscale/issues/15186) (opened 2025-03-03, closed) — "the Tailscale network extension failed to start," console showing `Memorystatus failed with unexpected error`. Recovery-by-toggle is the recurring workaround across [#6829](https://github.com/tailscale/tailscale/issues/6829), [#12245](https://github.com/tailscale/tailscale/issues/12245), [#15617](https://github.com/tailscale/tailscale/issues/15617) (Tailscale 1.80.2 / iOS 18.4, April 2025). *[inference: an extension that stalls identically on Wi-Fi and LTE, ignores an app force-quit, and recovers instantly on VPN toggle is consistent with the extension process being wedged or jetsam-restarted — i.e. this bug class is active in 2026, and it is not fixable from Tavi's side.]*

**tsnet.** Go library embedding a full Tailscale node in-process using a **gVisor userspace netstack** — no TUN, no root, no daemon ([pkg.go.dev](https://pkg.go.dev/tailscale.com/tsnet)). BSD-3. Named users: XeDN (~10 TB/mo), proxy-to-grafana, tclip. Go-only is its stated weakness. For Tavi's Node host it means a Go sidecar binary. Still requires a coordination server (Tailscale's control plane or Headscale) and Tailscale's DERP relays.

**The important find: TailscaleKit.** [`tailscale/libtailscale`](https://github.com/tailscale/libtailscale) (BSD-3) exposes tsnet as a C library, and its `swift/` directory builds **TailscaleKit.framework for iOS** with `make ios`, explicitly "free of any simulator segments and **suitable for app-store submissions**" ([README](https://github.com/tailscale/libtailscale/blob/main/swift/README.md)). The API is NWConnection-shaped, Swift 6, async/await, plus a URLSession extension for tailnet URLs. Caveats stated: Xcode 16.1+, LocalAPI "somewhat incomplete," nodes need auth keys or interactive auth, frameworks unsigned. Tailscale themselves ship a proof: [`tailscale/aperture-plus`](https://github.com/tailscale/aperture-plus), an **experimental** WebKit browser that reaches a tailnet "**without running the system VPN**" via an embedded userspace node and a local SOCKS5 proxy, split-tunnelling only 100.64.0.0/10 / fd7a::/48. iOS 26 / Xcode 26 / Go 1.26.5, ~200 commits, 14 stars, "TSNet exit nodes don't function properly," no App Store or background guidance. *[inference: this is the one option that removes the phone's NetworkExtension while keeping the existing tailnet addressing and ACLs unchanged — but it is experimental, Go-runtime-plus-gVisor sized, and a Go binary inside an iOS app has real size and startup cost.]*

**Shipping your own packet tunnel** is the alternative and a bad one: App Review 5.4 restricts VPN apps *[recalled, not verified — the guidelines page truncated on fetch]*, and you would inherit the same 50 MB extension budget that is causing the stall.

---

## 7. Userspace WireGuard in-app

**boringtun** (BSD-3) is exactly the primitive described: it "implements the underlying WireGuard protocol, **without the network or tunnel stacks**, those can be implemented in a platform idiomatic way," supports `aarch64-apple-ios`, and is "deployed on millions of iOS… consumer devices" via Cloudflare's 1.1.1.1 app ([repo](https://github.com/cloudflare/boringtun)). The README currently advises using the crates.io release rather than master while the repo is restructured. So yes: you can do Noise handshake + transport encryption over a plain UDP socket in-app with no TUN and no NE.

What you would still have to build yourself: **NAT traversal and relaying**. WireGuard has no hole punching and no relay — magicsock and DERP are Tailscale additions on top. *[inference: this option is "write your own iroh," and the endpoint-discovery/path-switching logic is precisely the part iroh spent 2024–2026 rewriting twice.]* No app is publicly known to do userspace WireGuard on iOS with a custom relay.

---

## 8. Nebula / ZeroTier / NetBird / Netmaker / Headscale

All the mesh VPNs are TUN-shaped on iOS. Nebula's official mobile client ([DefinedNet/mobile_nebula](https://github.com/DefinedNet/mobile_nebula)) embeds Nebula as a **gomobile** `MobileNebula.xcframework`; Nebula core is MIT. Whether a `tun.disabled` userspace mode is usable in-app is not documented in the repo — *[inference: Nebula's no-TUN modes exist for lighthouse/relay roles, not for app-level sockets.]* ZeroTier's **libzt** is the one genuine "userspace BSD sockets, no kernel driver" SDK with documented iOS/iPadOS framework builds — but it is **BSL 1.1**, and "building closed-source apps and devices based on ZeroTier requires a commercial license" ([repo](https://github.com/zerotier/libzt)), which rules it out for a paid App Store product without buying a licence. NetBird, Netmaker and Headscale are control planes over WireGuard; their iOS clients are packet-tunnel-based, and Headscale is only a Tailscale control-plane replacement — it changes nothing about the phone's extension.

---

## 9. iOS platform constraints that apply to every option

`NWConnection` gives `viabilityUpdateHandler` (connection can/cannot send — reacts to link interruption), `pathUpdateHandler`, and `betterPathUpdateHandler(_ betterPathAvailable: Bool)` — a *notification* that a preferred path exists. **Nothing migrates automatically at the TCP layer; the app must reconnect** ([Apple docs](https://developer.apple.com/documentation/network/nwconnection/betterpathupdatehandler)).

Background sockets: the distinction is running vs **suspended**, not foreground vs background — iOS does not kill connections of a running app, but suspends the app shortly after backgrounding, and a suspended app's sockets stop ([forum 716118](https://developer.apple.com/forums/thread/716118)). A `UIApplication` background task buys tens of seconds. Background `URLSession` does **not** support WebSocket. `NWConnection` is suspended with the app. *[inference: a persistent phone→host connection while backgrounded is not achievable in 2026 without a NetworkExtension; the realistic design is fast, honest reconnect on foreground — which is what iroh-ffi integrations do deliberately. A third-party VPN extension like Tailscale's does keep the tunnel up, but it does not keep* your app's *socket alive once your app is suspended.]*

---

## Comparison

| | Hole punch | Relay fallback / who runs it | Migration on net change | iOS w/o NE | Node side | E2E crypto | Size (iOS) | Licence | Maturity |
|---|---|---|---|---|---|---|---|---|---|
| **iroh** | Yes (QNT-in-QUIC, QAD) | Yes — n0 US/EU/SG, or self-host `iroh-relay` | **Yes** — QUIC multipath, hot path swap (bug #3979 fixed in 0.98) | **Yes**, SwiftPM xcframework | `@number0/iroh` 1.0.0, raw QUIC streams | QUIC/TLS 1.3, always, incl. via relay | ~+7.7 MB/slice *(1 measurement)* | MIT/Apache-2.0 | **1.0, Jun 2026**; 1.1.0 Aug 2026 |
| **libp2p** | Yes (DCUtR) | Circuit relay v2 — you run it | Reconnect *[inference]* | **No usable Swift** — swift-libp2p has no QUIC/relay/DCUtR | js-libp2p viable | Noise/TLS | n/a | MIT/Apache | rust mature; **swift WIP** |
| **WebRTC DC** | Yes (ICE) | TURN — Cloudflare 1 TB free then $0.05/GB, or coturn | ICE restart, ~sub-1 s, DTLS/SCTP survive; documented failures | Yes, stasel/WebRTC | node-datachannel 0.33.3 | DTLS; TURN sees ciphertext | large, 15–40 MB *[inference]* | BSD (libwebrtc) / MPL-2.0 | mature but Google pod dead |
| **NWProtocolQUIC** | **No** | **No** | Undocumented | Yes | `node:quic` experimental | TLS 1.3 | 0 | Apple | listener support broken/evolving |
| **WebTransport** | **No** | n/a | No | Safari 26.4 only, no native Swift | @fails-components 1.5.3 ("ducttape") | TLS 1.3 | 0 | — | Baseline Mar 2026 (web only) |
| **MPTCP** | **No** | **No** | Handover, yes | Yes (`.aggregate` needs entitlement) | **macOS is client-only** — no Mac server | none of its own | 0 | Apple/Linux | shipping, narrow |
| **TailscaleKit / libtailscale** | Yes (magicsock) | Yes — Tailscale DERP | Yes (magicsock) | **Yes** — `make ios`, "suitable for app-store submissions" | tsnet Go sidecar | WireGuard Noise | Go + gVisor, large *[inference]* | BSD-3 | libtailscale + aperture-plus **experimental** |
| **boringtun in-app** | **No** — build it | **No** — build it | No | Yes | — | WireGuard Noise | small | BSD-3 | proven (1.1.1.1), but half a solution |
| **ZeroTier libzt** | Yes | ZeroTier roots | Yes | Yes (userspace sockets) | — | ZT E2E | — | **BSL 1.1 — commercial licence needed** | mature |
| **Nebula / NetBird / Netmaker / Headscale** | Yes (Nebula) | Lighthouse/relay | Yes | **No** — packet-tunnel clients | — | Noise | — | MIT / mixed | mature, wrong shape |

**Two cross-cutting constraints that bind every row:** no option keeps a connection alive once iOS suspends the app, short of a NetworkExtension; and every direct route to a home Mac behind CGNAT will fall back to a relay 15–30 % of the time, so relay capacity and its operator are a first-class design input, not a footnote.

*Note: the libp2p and mesh-VPN subagent had not returned when this was written; §2 and §8 are from my own primary-source fetches (swift-libp2p README, DCUtR spec, IPFS hole-punching post, libzt, mobile_nebula) and are thinner on js-libp2p and rust-libp2p QUIC specifics than the rest. The web-search budget for this session is exhausted; further digging needs `CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION` raised.*