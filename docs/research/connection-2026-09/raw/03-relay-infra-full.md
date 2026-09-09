<!-- verbatim final report of the research agent, 2026-09-09; condensed version in ../03-relay-infra.md -->

Research complete. Here is the report.

---

# Relay/rendezvous options for Tavi — factual research
*Compiled 2026-09-09. Every number carries a source URL and the page date where the page showed one. Lines marked **ESTIMATE** are my arithmetic, not vendor claims. Gaps are marked rather than filled.*

## 0. The workload used for all cost arithmetic (ESTIMATE)

2,000 concurrent sessions × 2 h/day × 30 days = **120,000 session-hours/month = 432,000,000 session-seconds**. Two endpoints per session (phone + host) ⇒ **14.4 M connection-minutes/month**. At 2 KB/s per session one-way the relay forwards **~885 GB/month**, or **~1,770 GB** counting both legs; at 5 KB/s, ~2,212 / 4,424 GB. Frame rate assumed 2–10 small frames/s/session ⇒ **864 M – 4.32 B one-way messages/month** (1.7 B – 8.6 B counting both relay legs).

---

## 1. Cloudflare

### (a) Tunnel / cloudflared
- `cloudflared` dials **outbound only** on port 7844; default transport is **QUIC**, falling back to HTTP/2 if UDP is blocked. QUIC connections use post-quantum crypto by default; the HTTP/2 fallback does not. ([run-parameters docs](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/cloudflared-parameters/run-parameters/); [blog](https://blog.cloudflare.com/getting-cloudflare-tunnels-to-connect-to-the-cloudflare-network-with-quic/))
- WebSockets are proxied via ingress rules. "Each connector sends traffic to the nearest Cloudflare data center." No numeric concurrency, duration or byte limits are published on the overview page (last updated **2026-08-04**). ([overview](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/))
- Widely-cited limits (1,000 tunnels/account, 100 connections/tunnel, 200 in-flight requests on Quick Tunnels) appear only in community sources — **UNVERIFIED** against primary docs.
- **Path shape**: client → nearest anycast colo → Cloudflare backbone → colo nearest the connector → cloudflared → origin. Argo Smart Routing changes the middle leg; its pricing page 404'd on fetch, so the commonly-quoted $5/zone + $0.10/GB is **UNVERIFIED**.
- **ToS**: the old "Section 2.8 non-HTML content" clause was **removed from the Self-Serve Subscription Agreement in May 2023** — Cloudflare wrote that it "didn't make much sense" and moved it into CDN-specific Service-Specific Terms, eliminating "the antiquated HTML vs. non-HTML construct" ([blog, 2023-05-16](https://blog.cloudflare.com/updated-tos)). Current wording (Service-Specific Terms, last updated **2026-06-02**): Cloudflare "reserves the right to disable or limit your access to or use of the CDN … if you use or are suspected of using the CDN without such Paid Services to serve video or a disproportionate percentage of pictures, audio files, or other large files." ([source](https://www.cloudflare.com/service-specific-terms-application-services/)) It is framed around **the CDN product**; whether it reaches a WebSocket relay on Tunnel/Workers is not stated anywhere I could find — **UNVERIFIED**.
- **Outage history (Cloudflare's own postmortems)**: **2025-11-18**, 11:20–17:06 UTC global outage; a ClickHouse permissions change produced duplicate rows in a Bot Management feature file, pushing it past a 200-feature limit and panicking the core proxy; Workers KV, Access, Turnstile and the dashboard were hit. Cloudflare called it their "worst outage since 2019" ([postmortem](https://blog.cloudflare.com/18-november-2025-outage/)). **2026-02-20**, 17:56–23:03 UTC (6 h 07 m): an automated BYOIP cleanup bug withdrew 1,100 of 4,306 prefixes (~25%) via BGP; **Spectrum failed to proxy traffic** ([postmortem](https://blog.cloudflare.com/cloudflare-outage-february-20-2026/)). On **2026-05-01** Cloudflare published "Code Orange: Fail Small," a resilience programme explicitly framed as a response to that pattern ([post](https://blog.cloudflare.com/code-orange-fail-small-complete/)).
- Network: **348 cities**, "95% of the world's Internet-connected population is within 50 milliseconds of a Cloudflare data center — most are within 20 ms", 13,000+ interconnects ([cloudflare.com/network](https://www.cloudflare.com/network/), fetched 2026-09-09).

### (b) Workers + Durable Objects with WebSocket Hibernation

| Fact | Value | Source (page date) |
|---|---|---|
| DO placement | instantiated "in a data center close to where the initial `get()` request is made"; **DOs do not relocate after creation**; `locationHint` only on first `get()`, "best effort and not a guarantee" | [data-location](https://developers.cloudflare.com/durable-objects/reference/data-location/) (2026-06-26) |
| `locationHint` values | wnam, enam, sam, weur, eeur, apac, apac-ne, apac-se, oc, afr, me | same |
| Max WS message | **32 MiB** received | [DO limits](https://developers.cloudflare.com/durable-objects/platform/limits/) (2026-06-01) |
| Hibernation billing | "Durable Objects that are idle and eligible for hibernation are **not billed for duration**, even before the runtime has hibernated them" | [DO pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/) (2026-08-25) |
| WS message billing | "There is **no charge for outgoing WebSocket messages** … a **20:1 ratio** is applied to incoming WebSocket messages" | same |
| Workers Paid | $5/mo base; 10 M requests incl. then **$0.30/M**; 30 M CPU-ms incl. then $0.02/M CPU-ms; **no egress/bandwidth charge** | [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/) (2026-08-28) |
| DO requests / duration | 1 M requests incl. then **$0.15/M**; 400,000 GB-s incl. then **$12.50/M GB-s** | [DO pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/) (2026-08-25) |

**Monthly cost ESTIMATE at the stated workload**, assuming ~10 incoming frames/s/session ⇒ 4.32 B incoming messages/month ⇒ 216 M billable DO requests after the 20:1 divisor: 215 M × $0.15/M ≈ **$32**; duration at 128 MB × 1 ms active per message ≈ 553 k GB-s, overage ≈ **$2**; base **$5**. **≈ $39/month.** The duration line swings ~10× either way on the per-message CPU assumption, which is not published. The absence of any egress charge is the structural difference from every other option here.

### (c)–(e) Spectrum, Realtime TURN, long-connection limits
- **Spectrum**: "Custom TCP/UDP applications require an Enterprise plan with Spectrum as a paid add-on"; **no published per-GB rate** ([docs](https://developers.cloudflare.com/spectrum/), 2026-04-23).
- **Realtime (TURN)**: free when used with the Realtime SFU, otherwise **$0.05 per real-time GB** outbound to the TURN client ([docs](https://developers.cloudflare.com/realtime/turn/), 2026-09-09). A "first 1,000 GB free/month" figure appeared on a linked pricing anchor — less firmly sourced.
- **Connection duration**: no documented cap; "No hard limit while the caller stays connected to the Durable Object" ([limits](https://developers.cloudflare.com/durable-objects/platform/limits/), 2026-06-01).
- **Deploys evict DOs**: "A Durable Object may be replaced in the event of a network partition or a **software update (including either an update of the Durable Object's class code, or of the Workers system itself)**. Enabling `wrangler tail` or dashboard logs requires a software update." ([known issues](https://developers.cloudflare.com/durable-objects/platform/known-issues/), 2026-07-03). In-memory state does not survive eviction/hibernation; only Storage API data and hibernation attachments do ([in-memory-state](https://developers.cloudflare.com/durable-objects/reference/in-memory-state/), 2026-06-29).
- Subrequests: 50 (Free) / 10,000 (Paid) per request; **6 simultaneous outbound connections per request, and outbound WebSockets count** ([Workers limits](https://developers.cloudflare.com/workers/platform/limits/), 2026-09-05).
- **SLA**: Workers Enterprise SLA commits to **99.99% Monthly Uptime**, credits 10/25/50% at <99.99 / <99.9 / <95%; uptime = 100% minus the average 5-minute error rate of 500/502/503/504s. Excludes "the unavailability or performance degradation of interdependent Cloudflare services upon which the Worker relies," including storage bindings. Effective **2026-04-01** ([Workers SLA](https://www.cloudflare.com/workers-service-level-agreement/)). This is Enterprise-only; no SLA attaches to Free/Pro/Business self-serve Workers.

---

## 2. Fly.io

- **Anycast**: same IP blocks announced via BGP from every datacenter; edge proxy forwards to workers over an internal WireGuard mesh. `fly-replay` can re-issue a request in another region/Machine (requests >1 MB cannot be replayed) ([fly-replay docs](https://fly.io/docs/reference/fly-replay/)).
- **18 regions** as of fetch: iad, ewr, ord, dfw, lax, sjc, yyz, gru, ams, arn, cdg, fra, lhr, **bom**, nrt, **sin**, syd, jnb ([regions](https://fly.io/docs/reference/regions/), fetched 2026-09-09).
- **Pricing** ([about/pricing](https://fly.io/docs/about/pricing/), fetched 2026-09-09): shared-cpu-1x 256 MB **$2.02/mo** ($0.0028/h); 512 MB **$3.32/mo**; extra RAM ~$5/GB/30 d; billed per second. Stopped machines still cost **$0.15 per GB of rootfs per 30 days**.

| Egress region group | Public | Private (cross-region WireGuard) |
|---|---|---|
| North America & Europe | **$0.02/GB** | $0.006/GB |
| Asia Pacific, Oceania, South America | **$0.04/GB** | $0.015/GB |
| **Africa & India** | **$0.12/GB** | $0.050/GB |

- **Monthly cost ESTIMATE**, 5 regions (iad/lax/fra/bom/sin), 2 machines each at 512 MB = **~$33 compute**; bandwidth at 1,770–4,424 GB relayed (both legs, split evenly) ≈ **$456 (low) to $2,281 (high)**, midpoint ≈ **$1,385/month**. India alone is roughly half the bandwidth bill at 6× the US/EU rate.
- **WebSocket idle timeouts**: community threads report the proxy closing idle TCP after ~30–60 s with configurable timeouts available on Pro via support ([community](https://community.fly.io/t/idle-tcp-connection-with-data-terminates-after-30-seconds/20419)) — **not an official spec**; an app-level keepalive would be needed (ESTIMATE).
- **Reliability**: **2024-10-22** global orchestration outage, ~7+ hours, from an expired CA cert for the deprecated Consul system — Fly called it "the longest significant outage we've recorded … in the history of the company" ([infra-log 2024-10-26](https://fly.io/infra-log/2024-10-26/)). Also 2024-10-24 (5-region load incident), 2024-11-25 (global API/deploy outage). Status page on 2026-09-09 showed recent smaller items: 2026-09-02/03 LAX→SJC upstream issues, 2026-08-30/31 ~50% packet loss in ORD ([status.flyio.net](https://status.flyio.net/)). No published SLA was located.

---

## 3. Other edge / anycast / managed options

| Platform | Long-lived WS? | Footprint | Pricing (fetched 2026-09-09) |
|---|---|---|---|
| **Deno Deploy** (new) | not stated in current docs | **2 regions** (Classic's 6 sunset **2026-07-20**) | Free 1 M req; Pro $20/5 M; Builder $200/25 M; +$2/M req, $0.20/GiB egress ([pricing](https://deno.com/deploy/pricing), [classic regions](https://docs.deno.com/deploy/classic/regions/) 2026-03-19) |
| **Vercel** | **Yes, Public Beta**, requires Fluid compute; connection closes at the function's max duration (default 5 min; 30 min extended, Pro/Enterprise beta) | n/a | billed as Function Active CPU + Fast Data Transfer; no idle-connection charge ([docs](https://vercel.com/docs/functions/websockets), 2026-08-10) |
| **Fastly Compute** | **passthrough only** — WS is handed off to origin, not terminated at edge; must be enabled by a superuser; incompatible with shielding and Next-Gen WAF; no C++ SDK support | n/a | not published on fetched pages ([docs](https://www.fastly.com/documentation/guides/concepts/real-time-messaging/websockets-tunnel/)) |
| **Bunny Magic Containers** | not confirmed for Containers (CDN product documents WS separately) | 41+ regions (secondary source) | $0.02/CPU-h, $0.005/GB-h RAM, Anycast IP $2/mo; egress $0.01 EU/NA, **$0.03 Asia**, $0.045 SA, $0.06 ME/Africa ([pricing](https://bunny.net/docs/magic-containers/pricing)) |
| **ngrok** | yes (product is a tunnel) | region/PoP list not found on any fetched page | Free/Hobbyist $10/PAYG $20 + $0.10/GB over 5 GB, $1/100k HTTP req, $2/100k TCP conns, $0.02/active-endpoint-hour; Enterprise "contracts starting at $10,000/year" ([pricing](https://ngrok.com/pricing)) |
| **AWS Global Accelerator** | n/a (L4 anycast front door) | 2 static anycast IPs | **$0.025/accelerator/hour** (~$18/mo) + DT-Premium $0.010–$0.105/GB by route, **on top of** normal egress ([pricing](https://aws.amazon.com/global-accelerator/pricing/)) |
| **Hetzner** | own VM | Falkenstein, Nuremberg, Helsinki, Hillsboro OR, Ashburn VA, **Singapore (since 2024)** | prices JS-rendered, **not extracted** ([cloud](https://www.hetzner.com/cloud/)) |
| **DigitalOcean** | own VM | **16 DCs / 13 regions** incl. SGP1, BLR1 | cheapest Droplet **$4.00/mo** (512 MiB, 1 vCPU) with **500 GiB egress included** ([pricing](https://www.digitalocean.com/pricing/droplets)) |
| **Vultr** | own VM | pages returned **403** to automated fetch — not verified | not verified |
| **Google Cloud global LB** | — | — | **not extracted** (pages truncated/404) |

**ngrok ToS is a hard constraint**: distributing the ngrok Agent to your customers "requires ngrok's prior written consent, grantable or withholdable at ngrok's discretion," and the AUP forbids customers to "rent, transfer, resell, lease, license, assign … or otherwise make available the ngrok Services … to third parties or offer it on a standalone basis" ([ngrok.com/tos](https://ngrok.com/tos), fetched 2026-09-09).

### Managed realtime services

| Service | Billing unit | Rate | Workload ESTIMATE (1.73 B relayed msgs/mo) |
|---|---|---|---|
| **Ably** | messages, conn-minutes, channel-minutes, data | **$2.50/M msgs** (volume → $0.50/M); $1.00/M conn-min (→$0.20); $0.25/GiB; msg size 64 KiB free / 256 KiB Pro; **99.999% SLA Enterprise only**; claims "6.5 ms message delivery latency"; "11+ regions and 700+ PoPs" ([pricing](https://ably.com/pricing)) | **$864 – $4,320** msgs + ~$14 conn-min + ~$442 data |
| **AWS API Gateway WebSocket** | messages in **32 KB** units + conn-minutes | **$1.00/M messages**, **$0.25/M connection-minutes**, max msg 128 KB, ping/pong free ([pricing](https://aws.amazon.com/api-gateway/pricing/)) | **$1,728 – $8,640** messages + **$3.60** conn-min |
| **AWS IoT Core** | messages in **5 KB** units + conn-minutes | **$1.00/M messages** (first 1 B; tiers beyond not captured), **$0.08/M connection-minutes**, max msg 128 KB ([pricing](https://aws.amazon.com/iot-core/pricing/)) | **~$1,728 – $8,640** + **$1.15** conn-min |
| **Azure Web PubSub** | units of 1,000 concurrent connections + outbound messages | "messages larger than 2 KB are counted as multiple messages of 2 KB each"; Standard = 1,000 conns/unit, max 100 units, **99.9% SLA**; **per-unit and per-million prices render as "$-"** on the page ([pricing](https://azure.microsoft.com/en-us/pricing/details/web-pubsub/)) | not computable — price placeholders |
| **Pusher Channels** | tier caps | Pro $99 (2,000 conns, 4 M msgs/day); Growth Plus $1,199 (30,000 conns, 90 M msgs/day); **10 KB max event payload, 413 beyond** ([pricing](https://pusher.com/channels/pricing/), [REST docs](https://pusher.com/docs/channels/library_auth_reference/rest-api/)) | workload ≈ 58 M msgs/day → above every published tier |
| **PubNub** | **MAU**, not messages | Free 200 MAU; Starter $98/1,000 MAU; Pro 10,000 MAU ≈ **$550/mo**, 25,000 ≈ $1,130; "<100 ms latency worldwide"; "up to 99.999% uptime SLA" (Pro) ([pricing](https://www.pubnub.com/pricing/)) | **~$550/month** at 10,000 users, message-volume-independent under the published model |

Note the structural fork: **per-message pricing (API Gateway, IoT, Ably) makes a keystroke-rate terminal expensive by two to three orders of magnitude versus Cloudflare's 20:1 incoming-WebSocket divisor with free egress, or versus raw VM egress.**

---

## 4. DERP (Tailscale)

- **DERP = "Designated Encrypted Relay for Packets"** — "a packet relay system (client and servers) where peers are addressed using WireGuard public keys instead of IP addresses." Frame protocol: 5-byte header (1 byte type + 32-bit big-endian length), 21 frame types, over an HTTP upgrade; **max packet 64 KB**; payloads relayed **opaquely**; multiple nodes in a region are meshed with single-hop forwarding ([pkg.go.dev/tailscale.com/derp](https://pkg.go.dev/tailscale.com/derp)).
- **Fleet**: **23 geographic regions**, "Most regions have at least three DERP servers" — Sydney, São Paulo, Toronto, Helsinki, Paris, Frankfurt, Nuremberg, Hong Kong, **Bengaluru**, Tokyo, Nairobi, Amsterdam, Warsaw, **Singapore**, Johannesburg, Madrid, Dubai, London, and 10 US cities ([DERP servers docs](https://tailscale.com/docs/reference/derp-servers)).
- **Relay choice**: clients latency-probe and pick the nearest region as "home DERP"; all connections start relayed and are upgraded to direct when NAT traversal succeeds ([how NAT traversal works, 2020-08-21](https://tailscale.com/blog/how-nat-traversal-works)).
- **Self-hosting**: `go install tailscale.com/cmd/derper@latest`, `derper --hostname=…`, `--verify-clients` to restrict to your tailnet. Requires **direct internet with no NAT and no load balancer** (they rewrite source addresses and don't support HTTP upgrade), ports 80/443/3478 open, ICMP allowed, and periodic updates for client compatibility. Custom regions use IDs 900–999 in the tailnet policy `derpMap`; `OmitDefaultRegions: true` disables Tailscale's. The docs call it "an advanced operation that requires significant resources" and give **no hardware sizing** ([custom DERP servers](https://tailscale.com/kb/1118/custom-derp-servers), last validated 2026-01-05).
- **Peer relays** (public beta, **2025-10-29**): any tailnet node can relay for peers over **a single UDP port**, giving "throughputs nearing that of a direct connection; often multiple orders of magnitude higher than Tailscale's managed DERP fleet." Tailscale tries peer relays before DERP. Two peer relays free on all plans ([blog](https://tailscale.com/blog/peer-relays-beta)). Docs confirm DERP has "limited quality of service characteristics … generally slower than direct connections and may offer lower maximum throughput" ([connection types](https://tailscale.com/docs/reference/connection-types), validated 2026-06-01).

---

## 5. Latency facts

**Inter-region RTT, Azure P50, 30 days ending 2026-07-30** ([Azure network latency](https://learn.microsoft.com/en-us/azure/networking/azure-network-latency)):

| Pair | ms |
|---|---|
| East US ↔ West Europe | 85–89 |
| East US ↔ West US | 66–69 |
| **East US ↔ Southeast Asia** | **224–228** |
| West Europe ↔ Southeast Asia | 169 |
| Central India ↔ East US | 198–204 |
| West Europe ↔ Central India | 135–140 |
| Southeast Asia ↔ Central India | 53 |
| Southeast Asia ↔ Japan East | 36–72 |
| Southeast Asia ↔ Australia East | 95 |

These confirm the premise: a single Singapore relay adds ~225 ms to a US client and ~170 ms to an EU client, before the radio leg.

**Access-network latency**: Opensignal-derived figures reported by secondary aggregators (not fetched from Opensignal directly — their report pages returned **403**): 4G LTE ≈ 50–62 ms, 5G ≈ 35–48 ms in the UK, with median 5G improving from 78 ms (Q3 2024) to ~67 ms (Q3 2025). Treat as **secondary/unverified**; these are end-to-end test-server RTTs, not radio-only.

**Perception of typing latency**
- Nielsen (1993, citing Miller 1968 and Card/Robertson/Mackinlay 1991): **0.1 s** is "the limit for having the user feel that the system is reacting instantaneously"; 1 s for uninterrupted flow; 10 s for attention ([NN/g](https://www.nngroup.com/articles/response-times-3-important-limits/)).
- Dan Luu, *Computer latency: 1977–2017*: measured end-to-end keypress-to-screen from **30 ms (Apple IIe, 1983)** to **300 ms (Symbolics 3620)**; modern machines 50–200 ms. He cites work showing "people can perceive latencies down to 2 ms or less" and that increasing latency reduces task accuracy, explicitly disputing the 100 ms "instantaneous" threshold ([danluu.com/input-lag](https://danluu.com/input-lag/)).
- **Mosh** (Winstein & Balakrishnan, USENIX ATC 2012): SSP maintains terminal state at both ends and sends diffs; sessions are keyed by a long-lived token, not an IP, so roaming Wi-Fi→cellular does not break them. **68–96% of user keystrokes could be echoed immediately**; over a ~500 ms-RTT commercial 3G link, **median keystroke response ~5 ms for Mosh vs ~503 ms for SSH**; evaluated against real traces (the paper's user study covers ~40–54 hours of logged sessions across 6–69 users depending on the dataset cited) ([paper PDF](https://mosh.org/mosh-paper.pdf); [USENIX](https://www.usenix.org/conference/atc12/technical-sessions/presentation/winstein)).

The Mosh result is the load-bearing latency fact: predictive local echo decouples *perceived* keystroke latency from network RTT for roughly 70–95% of keystrokes, which changes what the relay's RTT budget has to buy.

---

## 6. Availability math and SLAs

| Target | Downtime / 30-day month | / year |
|---|---|---|
| 99.0% | 432 min | 5,256 min (87.6 h) |
| 99.9% | 43.2 min | 525.6 min |
| 99.95% | 21.6 min | 262.8 min |
| **99.99%** | **4.32 min** | **52.6 min** |
| 99.999% | 26 s | 5.26 min |

| Product | SLA | Source |
|---|---|---|
| Cloudflare Workers (Enterprise) | **99.99%**, credits 10/25/50% | [Workers SLA](https://www.cloudflare.com/workers-service-level-agreement/), effective 2026-04-01 |
| Cloudflare Free/Pro/Business Workers, Tunnel, Durable Objects | no product-specific SLA located | — |
| AWS EC2 | **99.99% region-level**, 99.5% single-instance; credits 10/30/100% | [EC2 SLA](https://aws.amazon.com/compute/sla/), 2022-05-25 |
| AWS API Gateway | **99.95% per region**; credits 10/25/100% | [API GW SLA](https://aws.amazon.com/api-gateway/sla/), 2022-05-05 |
| Azure Web PubSub Standard | **99.9%** (Free tier: none) | [pricing](https://azure.microsoft.com/en-us/pricing/details/web-pubsub/) |
| Ably | **99.999%, Enterprise tier only** | [pricing](https://ably.com/pricing) |
| PubNub | "up to 99.999%", Pro only | [pricing](https://www.pubnub.com/pricing/) |
| Fly.io | none located | — |

**The client's network is excluded from every one of these.** AWS's API Gateway SLA excludes downtime "that result[s] from … factors outside of our reasonable control including any force majeure event or **Internet access or related problems beyond the demarcation point**," and anything "that result[s] from your equipment, software or other technology." Slack/Salesforce's SLA excludes unavailability caused by "**Internet service provider failure or delay**." Cloudflare's Workers SLA measures uptime as 100% minus the 5-minute-bucket rate of 5xx responses *at Cloudflare's edge* — a client that cannot reach the edge produces no measured error.

Session-level SLO publications (Zoom/Parsec/Discord "session success rate" style) were **not found**: Zoom's SLA page redirected and could not be fetched, and Slack's published SLA promises only "commercially reasonable efforts" with no percentage and no session-level definition. This remains an open gap.

---

## 7. Rendezvous: how often does a relay actually carry the traffic?

- **Tailscale, 2025-10-15**: "Internal metrics have indicated **success rates for direct NAT traversal well north of 90%** in typical conditions" — "more than nine out of 10 connections between Tailscale nodes end up being direct P2P links" ([NAT traversal improvements pt.1](https://tailscale.com/blog/nat-traversal-improvements-pt-1)). The peer-relays post repeats the >90% figure ([2025-10-29](https://tailscale.com/blog/peer-relays-beta)).
- **WebRTC, callstats.io (2016-04-08, billions of minutes, 100+ customers)**: "**22% of the conferences need some kind of TURN relay server**"; ~9% required TCP transport; overall session-setup failure rate **12%** ("1 in 8 sessions are never set up"), of which **85% were NAT/firewall traversal failures**; ~20% of connected sessions dropped afterwards ([webrtcHacks](https://webrtchacks.com/usage-stats/)). Higher figures for managed-firewall enterprise networks (30–70%) appear only in secondary sources — **unverified**.
- **What forces relaying** (Tailscale docs, validated 2026-06-01): networks that block UDP, and **hard NAT** — "devices behind hard NAT gateways with unpredictable port mappings cannot establish direct connections" ([connection types](https://tailscale.com/docs/reference/connection-types)). Mobile CGNAT is the canonical hard-NAT case; I could **not** find a primary measurement of CGNAT prevalence or of mobile-specific hole-punch success rates (APNIC blog search returned no matching posts, and the web-search budget was exhausted).
- **iOS constraint** (Apple TN2277, 2011-03-30, archived): "While the app is suspended **the system may choose to reclaim resources out from underneath a network socket** used by the app, thereby closing the network connection … all networking operations on the socket will fail," typically surfacing as `EBADF`. The only mechanism that prevents reclamation is the VoIP-socket registration: "The socket's resources are never reclaimed." Otherwise Apple's guidance is to close on background and reopen on foreground, or use `beginBackgroundTaskWithExpirationHandler:` for bounded work ([TN2277](https://developer.apple.com/library/archive/technotes/tn2277/_index.html)). The modern `NEAppPushProvider` documentation is JS-rendered and could not be fetched — **gap**.

---

## Open gaps (stated, not filled)
Argo Smart Routing pricing (404); Cloudflare Tunnel numeric concurrency limits; DO eviction trigger thresholds; Fly.io official proxy idle-timeout spec and any SLA; Azure Web PubSub per-unit prices (rendered as "$-"); AWS IoT message tiers above 1 B; Vultr (403) and Hetzner (JS-rendered) pricing; GCP LB pricing; Deno Deploy's current region names and WebSocket policy; ngrok PoP list and latency claims; Opensignal primary latency figures (403); published session-level availability SLOs from consumer realtime products; primary CGNAT-prevalence measurements.