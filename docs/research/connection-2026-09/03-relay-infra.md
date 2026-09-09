# Relay / rendezvous infrastructure: facts (research agent, 2026-09-09)

Workload for arithmetic (ESTIMATE): 2,000 concurrent × 2 h/day → 120k session-hours/mo; ~885–2,212 GB one-way/mo; 0.9–4.3 B one-way msgs/mo.

## Cloudflare
- Tunnel/cloudflared: outbound-only 7844, QUIC (HTTP/2 fallback), WebSockets proxied, connector → nearest colo; no numeric limits published (overview 2026-08-04). Path: client → nearest colo → backbone → colo near connector → origin. Argo pricing UNVERIFIED (page 404).
- ToS: non-HTML clause removed May 2023; current Service-Specific Terms (2026-06-02) reserve right to limit CDN use for video/large files; applicability to Tunnel/Workers WS relay UNVERIFIED.
- Outages: 2025-11-18 (~6 h global, "worst since 2019"); 2026-02-20 (6 h 07 m, BGP prefix withdrawal, Spectrum failed); "Code Orange: Fail Small" 2026-05-01.
- Network: 348 cities; 95 % of population within 50 ms, most within 20 ms.
- Workers + Durable Objects: DO placed near first get(), never relocates; locationHint best-effort (wnam, enam, sam, weur, eeur, apac, apac-ne, apac-se, oc, afr, me). Max WS message 32 MiB. Hibernating DOs not billed for duration. Outgoing WS messages free; incoming billed at 20:1. Workers Paid $5 + $0.30/M req; DO $0.15/M req, $12.50/M GB-s. No egress charge. ESTIMATE at workload ≈ $39/month.
- DOs are evicted on class deploy or platform update (in-memory state lost; hibernation attachments + Storage survive). No connection duration cap. 6 simultaneous outbound connections per request incl. WS.
- Spectrum: Enterprise only. Realtime TURN: $0.05/GB. Workers SLA 99.99 % Enterprise only (effective 2026-04-01); none for self-serve.

## Fly.io
- Anycast + WireGuard mesh; fly-replay. 18 regions incl. bom, sin, syd, jnb, gru. shared-cpu-1x 256 MB $2.02/mo; 512 MB $3.32.
- Egress: NA/EU $0.02/GB; APAC/OC/SA $0.04; Africa & India $0.12/GB.
- ESTIMATE 5 regions × 2 machines ≈ $33 compute + $456–2,281 bandwidth (India ≈ half). Idle TCP ~30–60 s proxy timeout (community, unofficial).
- Outages: 2024-10-22 ~7 h global (expired Consul CA cert, "longest in company history"); 2024-10-24, 2024-11-25; 2026-08/09 regional packet loss. No SLA located.

## Others
- Deno Deploy: 2 regions now. Vercel WS public beta, closes at function max duration (5–30 min). Fastly Compute: passthrough only. Bunny Magic Containers: $0.02/CPU-h, egress $0.01–0.06/GB. ngrok: PAYG $20 + $0.10/GB + $2/100k TCP conns + $0.02/endpoint-hour; Enterprise ≥ $10k/yr; **ToS forbids redistributing the ngrok agent to customers without written consent**. AWS Global Accelerator $18/mo + premium DT. DigitalOcean $4 droplet w/ 500 GiB egress; 13 regions incl. SGP1, BLR1. Hetzner: FSN/NBG/HEL/HIL/ASH/SIN.
- Managed realtime at workload: Ably $864–4,320 msgs; AWS API GW WS $1,728–8,640; AWS IoT similar; Pusher above every tier (10 KB payload cap); PubNub ~$550/mo at 10k MAU. Per-message pricing is 2–3 orders of magnitude worse than Cloudflare's 20:1 divisor with free egress or raw VM egress.

## DERP
- Opaque packet relay keyed by WireGuard pubkey; 5-byte frame header; 64 KB max; HTTP upgrade; regions meshed. 23 regions incl. Singapore, Bengaluru, Tokyo, Hong Kong, Dubai, Nairobi.
- Client latency-probes, picks "home DERP"; all connections start relayed, upgrade to direct.
- derper self-host: needs public IP, no NAT/LB, 80/443/3478, "advanced operation"; no sizing published. Custom regions 900–999.
- Peer relays (beta 2025-10-29): any node relays over one UDP port; near-direct throughput; tried before DERP. DERP "generally slower … lower max throughput".

## Latency
- Azure inter-region P50 (2026-07): East US↔SE Asia 224–228 ms; W Europe↔SE Asia 169; Central India↔East US ~200; W Europe↔Central India ~137; SE Asia↔Central India 53; East US↔W Europe ~87.
- LTE ≈ 50–62 ms, 5G ≈ 35–48 ms end-to-end (secondary, unverified).
- Perception: 100 ms "instantaneous" (Nielsen/Miller); Dan Luu: perceivable to 2 ms, historic best 30 ms keypress→screen. Mosh: 68–96 % keystrokes echoed immediately; 5 ms median vs 503 ms SSH on 3G.

## Availability
- 99.99 % = 4.32 min/month, 52.6 min/year. 99.9 % = 43 min/month.
- SLAs: CF Workers Enterprise 99.99; AWS EC2 region 99.99; API GW 99.95; Azure Web PubSub 99.9; Ably/PubNub 99.999 Enterprise; Fly none.
- Every SLA excludes the client's network and ISP; CF measures 5xx at the edge, so an unreachable edge is not counted.

## Relay share
- Tailscale 2025-10: direct NAT traversal "well north of 90 %"; hard NAT (unpredictable ports) cannot go direct. Mobile CGNAT = canonical hard NAT; no primary mobile-specific hole-punch success measurement found.
- WebRTC (callstats 2016): 22 % of sessions need TURN; 12 % setup failures, 85 % of those NAT; ~20 % of connected sessions later drop.
- iOS TN2277: suspended app's sockets may be reclaimed (EBADF); close on background, reopen on foreground.

## Gaps
Argo pricing; Tunnel numeric limits; DO eviction frequency; Fly idle timeout spec/SLA; Azure prices; Hetzner/Vultr/GCP pricing; ngrok PoPs; mobile CGNAT hole-punch rates; session-level SLOs from consumer products.
