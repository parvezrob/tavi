# iOS networking constraints and the Tailscale iOS stall class: facts (research agent, 2026-09-09)

## 1. Tailscale iOS stall = known, OPEN bug class; signature matches ours
- tailscale#19504 (opened 2026-04-23, OPEN, active 2026-09-06): "iOS 26.4.1 + Tailscale 1.96.5 — MagicSock ReceiveIPv4 goroutine stops, data plane dies while control plane stays up". Node shows Connected; peer ping times out; warning `magicsock-receive-func-error`. VPN toggle, force-quit, reinstall, Wi-Fi/cellular switch "same result on both" per reporter. Third-party root-cause post (2026-08-21, libtailscale fork): IPv4 receive closure gets ENOTCONN before replacement socket installed → wireguard-go kills the receive goroutine → Rebind() installs a socket nobody reads. **Remote-terminal clients specifically trigger it**: SSH/tmux "every 2–3 minutes" (2026-08-19); Belay Mobile TestFlight: "interactive SSH terminal appears to reliably expose the same failure … toggling Tailscale restores connectivity immediately" (2026-07-21), recurred even after closing SSH on background; mosh/tmux "fails again within 15 mins" (2026-08-11).
- tailscale#18889 (2026-03-05, OPEN): connectivity fails shortly after connecting on iOS 26.4; toggle helps briefly.
- tailscale#15271 (2025-03-10, OPEN): "iOS MagicSock fails. UDP/DERP fails." Status when failing: **UDP = No** (our `udp=false`). Toggle "typically but not always" fixes.
- tailscale#14320 (2024-12, closed 2026-06-30 without fix, same symptom continues), #17967 (2025-11, OPEN: idle phone, cellular→Wi-Fi return), #6075, #8183, #8022, #15617, #6829.
- tailscale#15776 (2025-04, OPEN, P1): clients do not promptly detect DERP loss; keepalives are unidirectional (server→client); no active assertion after network change. Explains "why DERP didn't carry TCP" plausibly.
- tailscale#20622 / #20616 (macOS 2026-07, OPEN): same shape one layer down; silent relay-only for 5 days; only relaunch recovers.
- tailscale#21125 (2026-09-04, OPEN, iOS): per-peer /32 routes make route updates slow; "connectivity through the tunnel stalled until the VPN was toggled"; override `one-cgnat?v=true`.
- Versions: App Store 1.102.3 (2026-08-19). 1.102.1 fixed a wake-from-sleep wireguard-go issue; 1.98.8 similar; 1.96.5 fixed extension OOM on large tailnets.
- On Demand: Tailscale auto-configures broad On Demand; #21163 (2026-09-09) On Demand breaks LAN TCP after cellular; #20755, #18292, #15645. DNS confounds #12352, #17537 (DNS loss ⇒ loss of connectivity to nodes). User workaround claim: disable "Use Tailscale DNS" (unverified). No `includeAllNetworks` on iOS (#19489).

## 2. NetworkExtension
- 50 MiB phys_footprint jetsam cap per Tailscale's own test code (tstest/membudget, mem_ios.go); ~15 MiB non-heap. Staff confirm speed tests OOM the extension (#19810). Crash-loop example #20963. Our case (single pid, 27–33 MB) ⇒ receive-goroutine class, not OOM.
- NEProvider sleep()/wake() have no promptness guarantee. No public API lets one app restart another vendor's VPN.

## 3. App-side
- TN3151 (2026-07-23): "Unless you have a specific reason to use URLSession, use Network framework for new WebSocket code"; "consider QUIC instead of TCP" for custom protocols. New Swift `NetworkConnection` API in iOS 26.
- viabilityUpdateHandler / betterPathUpdateHandler: signal only; app does make-before-break. waitsForConnectivity = establishment only.
- MPTCP: needs server support (Linux MPTCP kernel; not macOS host) + entitlement. Non-starter for Mac hosts.
- TCP keepalive knobs exist on NWConnection (enableKeepalive/idle/interval/count), not URLSession. Dead-peer detection on LTE/CGNAT = app ping deadline only.

## 4. Background
- beginBackgroundTask: finite, undocumented; ~30 s is folklore. BG tasks cannot sustain a socket. APNs background push: not guaranteed, ≤2–3/hour, coalesced; alert pushes are the "needs you" path.

## 5. QUIC
- NWProtocolQUIC iOS 15+, idleTimeout, datagrams, NWMultiplexGroup. WWDC21 describes migration as a protocol property; Apple's shipping client migration unverified. apple/swift-network-evolution (2026-05, SPI-only) has Migration.swift with open TODOs ⇒ migration real but incomplete. Multipath QUIC still draft-21 (2026-08-13).
- Node: `node:quic` behind --experimental-quic, "early development", unpublished docs; Node 26.8.1 current. `@fails-components/webtransport` 1.6.8 (2026-09-06, ~50k dl/wk) works server-side; no Apple WebTransport client API.

## 6. Cellular NAT
- RFC 4787: UDP mapping ≥2 min, 5 min recommended; deployed reality "common value for UDP is 30 seconds" (Tailscale). Hard NAT (per-destination mappings) ⇒ no direct. Tailscale: direct >90 % overall; every connection starts on DERP. No primary mobile-specific numbers.

## 7. App Review
- 4.2.3(i): "Your app should work on its own without requiring installation of another app to function." ← bears directly on Tailscale-only transport.
- 4.2.7 Remote Desktop Clients: if the client mirrors *specific software* rather than the host device generically, host+client must be on a LAN, thin clients for cloud apps not appropriate. Generic host mirrors are not so limited. (Positioning matters: Tavi = generic terminal/agent supervisor for a user-owned computer.)
- 5.4 governs offering VPN services (not us). 2.1 demo mode with back-end on. 2.5.5 IPv6-only networks.

## Gaps
Apple forums unsearchable; no Apple statement of the 50 MB cap; shipping iOS QUIC migration behaviour unknown; carrier NAT numbers unsourced.
