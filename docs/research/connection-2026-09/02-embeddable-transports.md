# Embeddable P2P / QUIC transports for iOS + Node: facts (research agent, 2026-09-09)

## iroh (n0-computer, Rust)
- 1.0.0 2026-06-15; 1.1.0 2026-08-25 (security fixes 2026-09-01). MIT/Apache-2.0. Pre-1.0 churn was heavy (0.90→0.98 in 6 months).
- QUIC (quinn fork "noq"); dial by ed25519 pubkey; hole punching via relay-coordinated disco + QUIC Address Discovery (replaced STUN 2025-09); mDNS local. E2E at QUIC/TLS with raw public keys; relays carry ciphertext.
- **0.96: QUIC multipath** — one connection keeps relay + direct paths at once; QUIC picks the sending path; app sees `Connection::paths()`. Healing connections: netmon detects interface change, re-probe, disco new addresses; peer learns within ~5 s. 0.98 fixed hole-punch restart after network change, faster relay health check. ⇒ Wi-Fi→LTE without new handshake; relay path carries traffic while direct re-punches.
- Relays: self-host `iroh-relay` 1.1.0 (same code as production). n0 managed: Community $0 (US/EU/SG, rate-limited, no guarantees); Pro $19/mo (10k conns, 100 GB then $0.09/GB, 5 MB/s cap); Dedicated $199/mo/region (60k conns, 250 GB, custom regions). Managed relays authenticated by default since 2026-06 (capability tokens). Nearest-relay-by-RTT selection: implied, not explicitly documented.
- iOS: iroh-ffi (UniFFI) v1.1.0 2026-07-16; SwiftPM + CocoaPods `IrohLib`; `cargo make swift-xcframework`. No NetworkExtension needed (plain UDP). Needs SystemConfiguration + CoreWLAN link (CoreWLAN is macOS-only — verify on iOS build). xcframework zip 44 MB all slices; thinned arm64 slice smaller — measure.
- Node: `@number0/iroh` 1.1.0 2026-07-16, napi prebuilds darwin-arm64, linux x64/arm64 gnu+musl. 13-month publish gap pre-1.0.
- Gotchas: free relays best-effort; no named third-party production users; hole-punch success rate unpublished.

## libp2p
- rust-libp2p QUIC mature; DCUtR hole punch measured ~70 % ±7 (4.4 M attempts, arXiv 2510.27500), TCP≈QUIC; 30 % stay relayed. Run own Circuit Relay v2. js-libp2p needs @chainsafe/libp2p-quic. **swift-libp2p: QUIC/TLS/relay/DCUtR/AutoNAT "not started"; experimental only.** Not viable on iOS without DIY FFI.

## WebRTC data channels
- iOS: stasel/WebRTC xcframework (largest binary of all options). Node: node-datachannel (libdatachannel, MPL-2.0) production-viable; werift pre-1.0.
- TURN: Cloudflare Realtime 1,000 GB free then $0.05/GB; coturn self-host. Needs signalling (we have host + pairing).
- Network switch = ICE restart (re-gather + checks), slower than QUIC path migration; SCTP has HOL blocking.

## QUIC on iOS directly / Node
- NWProtocolQUIC client works; **server side on Network.framework blocked** (NetworkListener can't accept MultiplexProtocol; Apple forums say hold off). No Apple doc asserting client migration. quinn supports client address change (`ServerConfig::migration`).
- node:quic experimental (--experimental-quic). @fails-components/webtransport "ducttape until native". WebTransport in Safari 26.4 (web API only, client→server, no hole punch; helps VPS not NAT'd Mac).

## MPTCP
- URLSession `.handover` needs no entitlement (only .aggregate). iOS-only config; **macOS is MPTCP client-only ⇒ Mac host cannot serve MPTCP**; Linux ≥5.6 fine. WebSocketTask inheritance unconfirmed. No NAT traversal, no relay.

## Tailscale as a library — most actionable
- tsnet: full node in-process with gVisor userspace stack, no TUN/root/daemon. **libtailscale (BSD-3) has `swift/` → `TailscaleKit.framework`; `make ios` = "suitable for app-store submissions"**; dial/listen to tailnet nodes + URLSession extension; NWConnection-shaped; Swift 6 async. Commits 2026-08-27..30. **tailscale/aperture-plus**: experimental iOS/macOS browser reaching the tailnet "without running the system VPN" via embedded userspace node + SOCKS5. Caveats: experimental, LocalAPI incomplete, frameworks unsigned, targets iOS 26, exit nodes don't work.
- ⇒ Removes the phone's NetworkExtension while keeping tailnet, DERP, existing host pairing. Runs inside the app process (app's memory budget, not the 50 MB NE cap), but is suspended with the app.
- Tavi owning its own packet tunnel: wrong direction (5.4 org-only, same 50 MB cap).

## boringtun in-app
- Protocol-only WireGuard, deployed on millions of iOS devices (1.1.1.1), aarch64-apple-ios. Feasible w/o NE, but no NAT traversal/relay — you rebuild magicsock + DERP.

## Nebula / ZeroTier / NetBird / Netmaker / Headscale
- All NE-based on iOS. Nebula lib has userspace UserDevice but nobody ships it on iOS. ZeroTier libzt is **BSL 1.1** (paid for closed-source). Headscale = own control server + tsnet/libtailscale path.

## iOS ceiling for every option
- viability/betterPath are advisory; app migrates itself. Background: app suspended shortly after backgrounding; background URLSession doesn't do WebSockets; NWConnection frozen. **No option keeps a socket serviced while suspended; even the Tailscale VPN today does not keep the app's socket alive.** Options differ only in the first seconds after foregrounding.

## Comparison (hole punch / relay / survives Wi-Fi→LTE / iOS w/o NE / Node / crypto / licence / maturity)
- iroh: yes / n0 or self-host / yes (multipath) / yes / @number0/iroh / QUIC raw pubkeys / MIT+Apache / 1.1 (2026-08)
- libp2p: ~70 % / self-run / reconnect / no Swift stack / ok / Noise / MIT+Apache / Swift not started
- WebRTC DC: yes / TURN (CF 1 TB free) / ICE restart / yes / node-datachannel / DTLS / BSD+MPL / mature, big binary
- NWProtocolQUIC: no / no / undocumented / yes / experimental / TLS / Apple / server blocked
- MPTCP: no / no / yes by design / yes / Linux only / none / Apple / URLSession-only
- TailscaleKit: yes (magicsock) / DERP by Tailscale or Headscale+own / yes / yes / Go sidecar for Node / WireGuard / BSD-3 / Swift layer experimental
- boringtun: no / no / n/a / yes / n/a / WG / BSD-3 / crypto only
