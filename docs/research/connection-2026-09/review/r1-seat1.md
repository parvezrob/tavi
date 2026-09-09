I read all six research documents and the requested repository sources. **Relay-first is defensible; this memo is not ready to implement.** Its central promises depend on session ownership, authentication, recovery, and routing behavior that the proposed phases have not yet established.

The strongest case **against** the recommendation is iroh: the memo compares a recently stabilized library against an unwritten transport system as though the latter were the mature choice. Iroh already integrates authenticated encryption, relay fallback, NAT traversal, and migration. Those capabilities address provider dependence and handover latency, not just bandwidth. Its [multipath implementation](https://www.iroh.computer/blog/iroh-0-96-0-the-quic-multipaths-to-1-0) makes it a credible primary candidate.

That does not establish iroh’s suitability on Tavi’s physical iPhone and supported Node platforms. The research explicitly leaves those questions open. **Move its spike before the transport commitment.** Test relay-only operation with UDP blocked, provider failure, suspension, interface changes, and binding cancellation—not merely direct-connect percentage. If it fails those gates, ordinary WebSockets remain a reasonable default. The memo’s ordering does not survive; its preference for reliable outbound relay connectivity does.

Cloudflare Tunnel also deserves a stronger case: it could carry the existing HTTP and WebSocket surface while removing the phone’s VPN dependency. TLS termination and deploy disconnects also affect the proposed Workers route; they are not distinguishing objections. Tunnel remains a useful pilot and comparison baseline, with an explicit content-trust model. It is not automatically the final answer. In particular, the cited [cloudflared issue](https://github.com/cloudflare/cloudflared/issues/1652) contains a later update retracting the supposedly reliable HTTP/2 workaround.

The options also omit **ordinary authenticated direct TLS/WebSockets for a public VPS**. That route needs neither hole punching nor an Apple QUIC server. Certificate provisioning and public exposure need design, but iroh is not its prerequisite.

For the Europe-to-Virginia customer, an illustrative budget is:

| Component or experience | Illustrative latency |
|---|---:|
| Phone ↔ European edge | 40 ms RTT, assumed |
| Europe ↔ Virginia backbone | About 87 ms RTT, research baseline |
| Virginia relay ↔ host | 5 ms RTT, assumed |
| End-to-end application RTT | **About 132 ms** |
| Authoritative character echo | **About 140–170 ms**, assuming prompt host processing |
| Eligible, correctly predicted character | Potentially **5–30 ms locally** |
| Cold connection and first screen | Several hundred milliseconds in favorable conditions; slow host readiness can add seconds |

These are calculations, not Tavi measurements. The [Azure measurements](https://learn.microsoft.com/en-us/azure/networking/azure-network-latency) are a datacenter baseline, not cellular evidence. A nearby edge does not eliminate the Atlantic crossing. Moving the DO between endpoints can produce similar latency, but equality requires comparable routes and processing; geography alone does not prove it.

The ranked findings are:

1. **BLOCKER — §4, Layer 2: route racing conflicts with terminal ownership.**  
   Claim: “keeps the first that completes the Noise handshake and delivers a snapshot, keeps one alternate warm.”

   Today, every terminal attachment claim supersedes its predecessor—even a compatible resume. The second successful candidate can therefore evict the winner and put the phone into a final `superseded` state. See the [ownership contract](/Users/parvezrobin/Projects/tavi/protocol/README.md:433).

   **Change:** separate candidate authentication from terminal attachment. Define one logical session owner, an explicit route-promotion operation, and generation checks that reject late messages from losing routes. A warm route must not independently claim the terminal. Preserve genuine takeover by another device. Establish this before racing, with tests for late `ready`, `superseded`, input, and close callbacks.

2. **BLOCKER — §0 and §4, Layer 1.2: the input guarantee exceeds the proposed mechanism.**  
   Claim: “Exactly-once across any reconnect.”

   Sequence numbers can deduplicate reconnects while the same host retains the relevant ledger. They do not resolve a host failure between writing to the PTY and recording delivery: replay risks duplication; suppression risks loss. “Highest applied” also needs contiguous ordering when old and replacement routes overlap.

   **Change:** define the guarantee’s boundary: device identity, logical input session, PTY incarnation, contiguous sequence, deduplication lifetime, and acknowledgement meaning. Across an unknown incarnation or lost ledger, preserve the existing [delivery-uncertain behavior](/Users/parvezrobin/Projects/tavi/protocol/README.md:473). Specify queue limits and expiry; do not automatically submit minutes-old input into a changed prompt. Test lost acknowledgements and delayed old-route input explicitly.

3. **BLOCKER — §4, Layer 1.7: the proposed cryptographic bootstrap does not exist.**  
   Claim: “host static key from the QR fingerprint; device static key minted at pairing.”

   The current fingerprint is a **64-bit truncated hash of a random secret**, not a public key or its established fingerprint. Devices receive bearer credentials, not asymmetric identities. See [pairing.ts](/Users/parvezrobin/Projects/tavi/apps/host/src/pairing.ts:74). A phone cannot derive a Noise responder key from that QR.

   **Change:** specify versioned key enrollment, an authenticated full host public key, binding of the device key to authorization, migration for existing pairings, rotation, and revocation across every route. Relay registration requires proof of key possession. Keep credentials inside the encrypted channel.

   Noise IK is reasonable after authenticated enrollment, but it is not the enrollment design. Compare maintained implementations with pinned end-to-end TLS before choosing. Do not put terminal mutations in replayable handshake payloads; the [Noise specification](https://noiseprotocol.org/noise.html) distinguishes those security properties.

4. **HIGH — §0: “A+” mixes incompatible metrics and unobservable conditions.**  
   Claims: “given the phone has any internet at all and the host process is up”; “99.99 % = 4.3 minutes per month.”

   A running host can have no working uplink or a wedged agent backend. Reaching one public website does not imply reaching either relay. Also, 99.99% of opening attempts is not 99.99% time availability; converting it to monthly minutes changes the denominator.

   **Change:** define separate user-attempt success, active-session interruption time, and recovery distributions. Count one user opening once, including failed attempts whose telemetry arrives later. Define success as authenticated, current state rendered and usable—not merely socket establishment. Report network failures and unknown attribution separately. Specify populations, measurement windows, and confidence; opt-in telemetry plus a chaos harness cannot by itself establish a fleet-wide four-nines promise.

5. **HIGH — §4, Layer 2 and §5: the recovery timing contradicts the target.**  
   Claims: “two misses = dead (10 s)” and “live screen back within 1 s.”

   A silent blackhole immediately after a healthy exchange cannot be recovered within one second if detection waits roughly ten seconds. A warm alternate removes some establishment time, not detection time. Two connections using the same disappearing Wi-Fi path may both fail.

   The 45-second comparison also misrepresents today’s terminal behavior: the [PRD](/Users/parvezrobin/Projects/tavi/docs/PRD.md:191) documents separate terminal heartbeat bounds and a two-second handover challenge. The 30–45-second server detector belongs to events.

   **Change:** budget detection, promotion, replay, and rendering separately. Distinguish explicit disconnects, observed handovers, and silent stalls. Either revise the silent-stall SLO or demonstrate a mechanism that meets it. Require authenticated **phone-to-host** challenges; an outer WebSocket pong from the relay proves only that the relay answered.

6. **HIGH — §4, Layer 3: neither complete routing nor provider independence is specified.**  
   Claims: “the host opens one WebSocket”; “no parsing”; “No control plane.”

   One host socket must distinguish phones, terminals, events, and request/response traffic. The app also uses HTTP for pairing, files, Git operations, and uploads, plus a separate preview door and `WKWebView`. A terminal-only relay does not deliver a usable Tailscale-free app. These surfaces are visible in [server.ts](/Users/parvezrobin/Projects/tavi/apps/host/src/server.ts).

   **Change:** define channel routing, fragmentation, bounded queues, backpressure, cancellation, and fairness so uploads cannot stall terminal traffic. Keep application payloads opaque while acknowledging the routing envelope and registration state.

   For fast provider failover, the host must already register with both providers and the phone must already know both addresses. Define duplicate-registration handling, hibernation recovery, admission limits, and independent bootstrap dependencies. Two vendors running identical faulty code do not make failure probabilities independent.

7. **HIGH — §0 and §4, Layer 1.3: predictive echo is being promoted from a heuristic to a universal guarantee.**  
   Claims: “≤ 30 ms regardless of RTT”; “70 %+ of keystrokes render instantly.”

   The cited result is Mosh’s measured workload, not Tavi’s coding-agent TUIs. Prediction cannot instantly provide authoritative completion menus, cursor movement, application responses, or previously unconfirmed echo behavior. Here the PTY is an attachment to herdr; waiting 50 ms after writing does not prove the ultimate application has rendered the input.

   **Change:** separate speculative feedback from authoritative response latency. Specify confirmation and rollback against renderer state, conservative treatment of hidden-input prompts, Unicode and IME behavior, and explicit acknowledgements when no output occurs. Mosh sometimes sends an additional acknowledgement message; merely adding a field to output frames misses that case. The [Mosh paper](https://mosh.org/mosh-paper.pdf) supports experimentation, not the promised Tavi percentile. Move prediction after transport correctness.

8. **HIGH — §4, Layer 1.1 and 1.6: snapshot restoration is substantially underspecified.**  
   Claims: “serialized emulator state”; “epoch, offsets, unacked input, last frame.”

   A saved image is not emulator state. The existing offset advances when bytes enter the renderer-owned queue, before they necessarily affect the displayed frame. Saving that offset beside an older frame would skip output after restoration. The [resume contract](/Users/parvezrobin/Projects/tavi/protocol/README.md:457) explicitly couples offsets to retained renderer state.

   The research names no usable Ghostty serializer. Tavi already gets a herdr repaint on a resume miss; introducing another host emulator needs justification.

   **Change:** prove an atomic checkpoint containing matching parser state, geometry, offset, and pending output—or show a cached image while obtaining a fresh authoritative repaint. Define secure storage, backup exclusion, expiry, and deletion for persisted terminal contents and input.

   Also, 4 MiB at 5 KiB/s covers **about 14 minutes**, not 30. Budget replay bytes, attachment lifetime, and aggregate host resources separately.

9. **HIGH — §5: phases 1 and 2 bundle major projects and reverse dependencies.**  
   Claim: “each phase ships value.”

   Phase 1 combines public infrastructure, cryptographic enrollment, two client integrations, and racing. Phase 2 combines input safety, prediction, emulator serialization, and lifecycle persistence. Meanwhile provider independence waits behind visual latency work.

   **Change the order:** observability and retained-frame fixes → immediate transport comparison spike → versioned trust/channel contract and one complete route → safe promotion plus second-provider operation → bounded input replay → crash restoration and retention tuning → predictive echo.

   A first route can ship with today’s explicit delivery uncertainty. Racing cannot ship before ownership is safe. Each transport gate should include the repository’s real-type slow-peer, never-returning-send, and close-mid-await tests, plus physical cellular checks.

10. **HIGH — §1 and §5, phase 0: “honest status” would assert a cause it cannot establish.**  
    Claim: “public-endpoint probe beside the host probe → `tunnelStalled`.”

    Public endpoint succeeds + host fails also describes host shutdown, host uplink failure, Serve failure, ACL rejection, and tunnel DNS trouble. The [incident report](/Users/parvezrobin/Projects/tavi/docs/history/2026-09-09-tailscale-stall/README.md) supports the phone-tunnel diagnosis through additional evidence and the VPN-toggle intervention; it does not validate this generic inference or prove the particular receive-goroutine defect.

    **Change:** report “Internet reachable; computer unreachable through Tailscale” with a troubleshooting action. Reserve stronger attribution for stronger evidence, such as simultaneous success through an independent host route. Include `unknown` in the status model. Tavi can detect failed end-to-end progress even though it cannot repair another app’s VPN.

11. **MEDIUM — §0, §3 and §6: infrastructure facts are overstated or stripped of qualifications.**  
    Claims: “two ~6 h global outages”; “≈ $40/month”; “DO … sits near the host.”

    The February incident affected approximately 25% of BYOIP prefixes; it was not a blanket Workers outage. Correct the scope using [Cloudflare’s postmortem](https://blog.cloudflare.com/cloudflare-outage-february-20-2026/).

    The $40 figure is an estimated workload case. Hibernation does not remove execution charges; [Cloudflare bills active processing duration](https://developers.cloudflare.com/durable-objects/platform/pricing/). The supplied research’s Fly bandwidth estimate alone exceeds the memo’s entire $40–150 range.

    Placement is [best effort](https://developers.cloudflare.com/durable-objects/reference/data-location/), not a region guarantee. **Change:** retain workload assumptions, processing-time sensitivity, provider-specific costs, and placement uncertainty. Select routes using measured end-to-end latency, not the number of advertised edge cities.

12. **MEDIUM — §3 and §6: platform conclusions exceed the evidence.**  
    Claims: “Live Activities is the emerging successor”; “a VPS the user rents counts”; “Word the listing that way.”

    Live Activities are not evidence of unrestricted background socket execution; [Apple documents a separate update mechanism](https://developer.apple.com/documentation/ActivityKit). The [App Review guidelines](https://developer.apple.com/app-store/review/guidelines/) do not explicitly establish the rented-VPS interpretation, and listing language cannot determine how the actual agent-focused functionality is classified.

    **Change:** retain suspension as the baseline regardless of Live Activities. Treat the generic-terminal classification as a reasoned position requiring early review validation, not an established exemption.

VERDICT: NOT APPROVED