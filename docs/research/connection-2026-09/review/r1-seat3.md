All six research files and the requested repository sources were readable. GitHub API access failed, so I could not verify live #37/#119 or PR state.

Ranked findings:

1. **BLOCKER — §4 Layer 1.7: the proposed trust anchor does not exist.**  
   Claim: “host static key from the QR fingerprint.”

   Today’s fingerprint is a **64-bit truncated hash of random secret bytes**, not an asymmetric public key or a certificate fingerprint ([pairing.ts](/Users/parvezrobin/Projects/tavi/apps/host/src/pairing.ts:74)). The current QR contains no public key. Noise IK requires the initiator to know the responder’s static public key; a fingerprint cannot supply it.

   **Change:** specify a versioned pairing format carrying the complete public key, with a human-verifiable fingerprint derived from that key. Bind the device key during the single-use pairing exchange. Define migration over the existing authenticated connection or explicit re-pairing; never learn a replacement trust anchor from an untrusted relay.

2. **BLOCKER — §4 Layer 3: relay addressing is being substituted for admission control.**  
   Claims: “authenticates with its public key”; “a phone opens a WebSocket to `wss://relay/<host-key>`”; “Rate limit per key.”

   Neither presenting a public key nor knowing a host address proves authorization. Random full-length keys resist brute-force enumeration, but observed keys—from URLs, logs, or leaked pairing material—allow targeted presence probing and unsolicited connection floods. Attackers can generate unlimited keys to evade sender-key limits; unauthenticated traffic can exhaust a victim’s host quota. Noise rejection at the host happens after relay resources and host bandwidth/CPU have been consumed.

   **Change:** require fresh proof of possession for host registration and a verifiable, host-issued device admission capability with possession proof for phones. Define a separate, bounded first-pairing admission flow. Apply pre-authentication limits, authenticated device/host quotas, handshake deadlines, bounded queues, and global abuse limits. Admission must precede expensive allocation; an unsolicited connection must never replace the registered host.

3. **BLOCKER — §4 Layers 1/3 and §5 Phase 1: “Noise E2E” leaves the actual encryption boundary unspecified.**  
   Claim: “inside every route … ciphertext only.”

   The existing client sends its shell-access bearer credential in the **outer HTTP upgrade header** ([TerminalWebSocketClient.swift](/Users/parvezrobin/Projects/tavi/apps/ios/Tavi/Features/Terminal/Transport/TerminalWebSocketClient.swift:106)). Redirecting that request to Cloudflare exposes the credential even if subsequent terminal frames use Noise. Pairing, ordinary HTTP APIs, uploads, and the separate WebKit preview door also need a defined encrypted path.

   Without E2E, a compromised relay can read credentials and inject commands. With correctly authenticated E2E, it still controls delivery, disconnects, and metadata. Noise IK’s initial payload is replayable; executing input during that flight is unsafe. [Noise security properties](https://noiseprotocol.org/noise.html#payload-security-properties).

   **Change:** specify the complete inner protocol, including authentication, HTTP/preview carriage, framing, negotiation, and fresh handshake confirmation before side effects. Keep host credentials out of outer headers. Authenticate permanent outcomes such as revocation and takeover inside the channel; a relay-supplied WebSocket close must not permanently disable every route. Choose a maintained Noise implementation or inner TLS before committing to the dependency estimate.

4. **HIGH — §2 and §4: device revocation and key rotation do not survive the proposed abstraction automatically.**  
   Claim: “revocation within 2 s.”

   That guarantee currently comes from checking each socket’s bearer credential against the host registry ([server.ts](/Users/parvezrobin/Projects/tavi/apps/host/src/server.ts:147)). A multiplexed host-to-relay socket authenticated as the host cannot inherit per-device authorization. Static device keys, warm routes, admission capabilities, and old bearer credentials create additional access paths.

   **Change:** retain one authoritative device registry at the host and bind every inner session to a device record. Revoke active and standby sessions across both providers, reject queued input, and enforce authorization without trusting relay cooperation. Specify device-key replacement, admission-capability expiry, host-key rotation, lost-key recovery, and legacy credential retirement. A host-key mismatch must stop automatic connection; a failed secure route must never trigger a weaker authentication fallback.

5. **HIGH — §4 Layers 1/2 and §5: route racing conflicts with current ownership, while input safety ships afterward.**  
   Claims: “keeps one alternate warm”; “Exactly-once across any reconnect.”

   Current v2 permits one owning connection per attachment. A second resume **supersedes the first**, and the losing phone stops retrying ([protocol contract](/Users/parvezrobin/Projects/tavi/protocol/README.md:433)). Racing terminal attachments can therefore make the phone evict itself.

   Sequence numbers also need a durable scope. If the host writes input, loses its deduplication state, and receives a resend, it can execute the command twice. A PTY write and an acknowledgment ledger are not one atomic transaction.

   **Change:** distinguish an authenticated standby transport from attachment ownership, with explicit promotion and fencing of the old route. Scope input sequencing to device, terminal, and ownership epoch. Promise deduplication only within a retained session; after ambiguous state loss, require reconciliation rather than automatic replay. Move these foundations before shipping automatic route switching. Test dropped acknowledgments, concurrent routes, takeover, and restart between write and acknowledgment.

6. **HIGH — §0: the four-nines argument mixes different metrics and assumes independence.**  
   Claims: “99.99 % = 4.3 minutes per month”; “two independent routes.”

   The table measures successful opening **attempts**, whereas 4.3 minutes describes time-based availability. Those are different budgets. Two-provider availability multiplies only under independence. Shared authoritative DNS, domain suspension, certificate renewal automation, deployment credentials, a defective shared release, and the client transport stack can disable both. Optional Tailscale does not protect customers who never install it.

   The condition “phone has any internet … host process is up” also leaves host internet loss, host firewall policy, and a wedged host/backend inside the promise.

   **Change:** define separate attempt and session-availability SLIs, their denominators, exclusions, and measurement windows. Model common-cause failures explicitly. Provision independently reachable DNS/TLS paths, separate provider credentials, staggered releases, and locally cached fallback configuration. Qualify using correlated failures and cold starts with empty DNS caches. Opt-in counters and a chaos harness alone do not establish population-wide four-nines performance.

7. **HIGH — §4 Layer 2: the heartbeat cannot meet the recovery target and may measure the wrong peer.**  
   Claim: “Heartbeat 5 s … two misses = dead (10 s).”

   A silent blackhole shortly after a successful heartbeat already violates the one-second recovery SLO before switching begins. A warm alternate does not shorten detection. Changing interfaces can also invalidate both warm TCP connections.

   More seriously, the existing events watchdog uses WebSocket pongs. Once that WebSocket terminates at a relay, a pong proves the **relay** answered while the host-facing connection may be dead.

   **Change:** separate phone-to-relay, relay-to-host, and authenticated end-to-end host liveness. Carry fresh challenges inside the encrypted channel. Specify detection, promotion, replay, and render budgets separately. Either weaken the one-second SLO for silent failures or implement and measure a mechanism capable of meeting it. Test a relay that keeps answering pings while discarding all host traffic.

8. **HIGH — §4 Layer 3: removing the directory leaves rendezvous unresolved.**  
   Claims: “No control plane”; “host choosing by RTT.”

   If the host selects Singapore and the phone connects to Ashburn, the host key alone does not connect those sockets. `/api/host` cannot teach the phone a new fallback location while the existing route is unavailable. Opening “one WebSocket” also does not establish simultaneous connectivity through two providers.

   **Change:** specify concurrent host registration with both providers and a rendezvous scheme: cached explicit endpoints, deterministic placement, or relay forwarding. Define regional failure, host relocation, stale configuration, multiple phones, and host replacement. This is coordination even without an account database.

   Authenticate before DO allocation as well: the first `get()` influences placement, and placement hints are best-effort. “Created by the host” must be enforced, not assumed. [Cloudflare placement documentation](https://developers.cloudflare.com/durable-objects/reference/data-location/).

9. **HIGH — §4 Layer 3 and §6: deployment recovery and operating ownership are missing.**  
   Claims: “~500 lines”; “A deploy evicts DOs … < 1 s stutter.”

   Cloudflare documents WebSocket disconnection on code updates. Hibernation is different: its socket attachments survive only while the connection survives. Neither gives a subsecond fleet-recovery guarantee. [WebSocket lifecycle documentation](https://developers.cloudflare.com/durable-objects/best-practices/websockets/).

   **Change:** define provider-by-provider rollout, verified standby readiness before deployment, connection draining for VPS relays, reconnect jitter, capacity for a complete provider failure, and mixed-version rollback. DO canaries should use the actual per-object rollout semantics. [Gradual deployments](https://developers.cloudflare.com/workers/versions-and-deployments/gradual-deployments/with-durable-objects/).

   Before 10,000 users, name the on-call owner and add external end-to-end probes, error-budget alerts, certificate-expiry monitoring, queue/FD/memory limits, abuse response, billing alarms, and incident runbooks. Bound retained PTYs as well as ring bytes. A provider-wide reconnect storm must be an exit test.

10. **HIGH — §6 and the PRD: E2E does not make the relay “blind,” and the product decision remains incomplete.**  
    Claim: “E2E makes it blind.”

    The relay sees host and phone IPs, stable host identifiers, connection relationships, timing, and volume. Racing both providers exposes that information to both even when Tailscale wins. URL/access logs, security systems, and provider diagnostics can retain it despite “no storage” in the forwarding code.

    The [PRD](/Users/parvezrobin/Projects/tavi/docs/PRD.md:28) prohibits requiring a hosted Tavi relay. Relay-default can coexist with that policy only if direct-only and self-hosted modes genuinely avoid Tavi infrastructure. The incident establishes the need for a Tailscale-independent route; it does not settle that privacy decision.

    **Change:** document and approve the default, provide a mode with no managed-relay contact, and update the PRD/onboarding. Define metadata fields, processors, purposes, retention, deletion, access controls, and telemetry consent. Suggested truthful wording: “Session content is encrypted between your phone and computer. Relay operators can observe connection metadata.”

    Privacy policy disclosures must cover actual sharing and retention. App Store labels depend on what is retained; merely forwarding transient data does not automatically require declaring content collection. [Apple privacy rules](https://developer.apple.com/app-store/review/guidelines/#privacy), [label guidance](https://developer.apple.com/app-store/app-privacy-details/).

11. **HIGH — §6 App Review: the rented-VPS exemption is asserted without support.**  
    Claim: “a VPS the user rents counts … Word the listing that way.”

    Apple’s text does not establish that a rented VPS counts as a user-owned personal computer. It also expressly addresses cloud-app thin clients. Generic terminal functionality supports Tavi’s case, but agent-specific supervision makes categorization an unresolved submission risk. Listing language cannot change the shipped behavior.

    **Change:** retain 4.2.3(i) as a legitimate risk of requiring another iPhone app. Treat 4.2.7 applicability as unresolved under #37. Suggested positioning: “A general-purpose remote terminal for computers you control, including your own Mac and separately provisioned Linux servers.” Explain that users administer the host and install their own tools; demonstrate arbitrary shell operation alongside agent features. Give reviewers a working isolated host and disclose VPS support explicitly. Seek review clarification rather than claiming an exemption. [Apple’s guidelines](https://developer.apple.com/app-store/review/guidelines/#minimum-functionality).

12. **HIGH — §4 Layer 1.6: background persistence introduces an unreviewed secret store.**  
    Claim: “snapshots … unacked input, last frame … to disk.”

    Pending input can contain passwords that the terminal never echoed. Frames can contain credentials and private source. Unconditional restoration can reveal them before Face ID, and replay after a long suspension can send stale input into a changed prompt.

    **Change:** define protected local storage, backup exclusion, expiry, deletion on unpair, and lock-screen/app-switcher behavior. Keep restoration behind the existing access gate. Persist application resume state rather than reusable transport cipher state. Revalidate the terminal and ownership epoch before any resend, and explicitly decide whether persisting raw pending input is acceptable.

13. **MEDIUM — §3/§6: the combined cost estimate contradicts its evidence base.**  
    Claims: “≈ $40/month at 10 k users”; “$40–150/month … across both deployments.”

    Research/03 estimates roughly $39 for an assumed workload, not for 10,000 users independently of usage. Its Fly estimate is **$33 compute plus $456–2,281 bandwidth**. That cannot support the combined figure.

    The Cloudflare estimate also depends on hibernation. Persistent timers or incompatible socket handling can incur duration charges. Illustratively, 120,000 billable object-hours at the documented 128 MB allocation cost roughly **$686 in duration alone**, after the included allowance. [Cloudflare pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/).

    **Change:** publish a reproducible model covering always-connected hosts, both traffic directions, message frequency, warm alternates, previews/uploads, failover capacity, and actual regional egress. Separate infrastructure from monitoring, support, and staffing. Label $40 an optimistic workload estimate pending measurement.

14. **MEDIUM — §1 and §5 Phase 0: the proposed “honest” status overdiagnoses the failure.**  
    Claims: “Nothing in Tavi can detect or repair it”; “public-endpoint probe … → `tunnelStalled`.”

    Tavi can detect failed reachability; it cannot repair another app’s VPN. Public internet success plus host failure cannot distinguish a stalled phone extension from host sleep, host internet loss, Serve failure, DNS, or tailnet policy. The incident report supports the VPN-toggle diagnosis retrospectively and explicitly leaves the DERP mechanism unexplained.

    **Change:** report “Internet reachable; computer unreachable through Tailscale.” Offer the recovery action as troubleshooting. Even an independent route reaching the same host proves only that the Tailscale route failed, not which component failed. Host-reported route health must carry freshness and remain “unknown” when supporting evidence is unavailable.

VERDICT: NOT APPROVED