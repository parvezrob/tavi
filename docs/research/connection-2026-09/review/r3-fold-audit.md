All supplied paths were readable. **V4 is not lockable: the admission redesign exposes the secret that authorizes pairing, allowing a malicious relay to obtain shell access.** Several other folds remain incomplete.

A = round-2 fold-audit; B = round-2 fresh-eyes review. “Folded correctly” means resolved at the planning level, including an explicit qualification gate.

| Round-2 finding | Disposition in v4 |
|---|---|
| A1 / B1 — admission deadlocks and possession proof | **Partially.** Returning-device admission is fixed; first pairing introduces the credential-theft path below. |
| A2 / B2 — TLS lifetime and HTTP mutations | **Folded correctly.** Affected connections close; consumers reconnect; ambiguous mutations are not automatically resubmitted. |
| A3 / B3 — proxy, origins, trust stacks, ALPN, tailnet TLS | **Partially.** Public proxy APIs, separate origins, three verifiers, HTTP/1.1 and host-terminated tailnet TLS are addressed. ATS handling remains unspecified; route-local rejection of a bad pin is **missed**. |
| A4 — revocation across all surfaces | **Partially.** Host enforcement covers previews and standby connections. The relay-admission delay remains overstated. |
| A5 / B4 — input acceptance, expiry and sequence gaps | **Partially.** Acceptance and uncertainty are corrected; fencing is the right direction. The fence boundary and phase-5 verdict categories still permit false conclusions. |
| A6 — activation ordering and host restart | **Folded correctly.** Conditional, queryable activation; three identifiers; host-incarnation revisions; explicit takeover. |
| A7 / B5 — screen reconstruction and geometry | **Partially.** Renderer loss and geometry changes force repaint. The quiet-period heuristic still violates the claimed screen invariant. |
| A8 / B6 — detection, warm routes and interface loss | **Partially.** Absolute deadlines, outer path events and interface-loss distinctions are fixed. Warm connection reuse and cold-start exit clocks remain inconsistent. |
| A9 / B8 — DNS/bootstrap and endpoint lifecycle | **Partially.** Independent DNS, cached addresses and registration generations are addressed. Cached-address expiry and recovery beyond the overlap window remain undefined. |
| A10 — interruption SLI | **Partially.** Arithmetic and attempt units are corrected. The replacement interruption definition counts healthy idle sessions as interrupted. |
| A11 — safety and operating gates | **Partially.** Ordering tests and operating readiness move before launch. Global admission bounds remain missing; the specified VPN test does not reproduce a stalled phone extension. |
| A12 — metadata, no-managed mode, display protection | **Folded correctly.** Explicit release criteria now cover these. |
| A13 — cost-model inputs | **Folded correctly.** The revised workload and required model inputs are explicit. |
| B7 — shared TCP head-of-line blocking | **Partially.** A separate bulk connection is appropriate, but the encrypted proxy has no specified mechanism for assigning API uploads to it. |
| B9 — comparative transport selection | **Folded correctly.** Equivalent workloads and an explicit selection replace prejudged adoption thresholds. |
| B10 — launch bargain, deployment floor, suspension | **Partially.** Launch phase, conservative input, iOS 26 and finite background execution are explicit. §8 still omits material launch limitations and delegates engineering choices to the owner. |

Ranked findings:

1. **BLOCKER — Layer 1.3: first-pairing admission gives the relay the pairing authorization secret.**

   The phone presents the single-use secret to the relay. A malicious relay can withhold that connection, establish its own TLS connection to the real host, redeem the secret with its own device key, and obtain a bearer credential. Host-key pinning authenticates the host; it does not authenticate the intended phone. Restricting the channel to `/api/pair` permits exactly this attack. The existing [pairing endpoint](/Users/parvezrobin/Projects/tavi/apps/host/src/routes/pairing.ts:10) grants a credential based on possession of that secret.

   **Fix:** use a separate admission credential that cannot redeem pairing. Keep the redemption secret exclusively inside pinned TLS. Define bounded admission retries after connection loss; “one channel” must not permanently consume onboarding before redemption succeeds. Test a malicious relay racing redemption and a disconnect before and after the host commits pairing.

2. **HIGH — §0: the interruption SLI is mathematically incompatible with healthy idle operation.**

   A quiet terminal receives authenticated challenges approximately every five seconds. Every such gap exceeds two seconds. Under the stated definition, essentially the entire healthy idle session becomes interruption time. Counting only the portion beyond two seconds would still count roughly 60%.

   Conversely, authenticated heartbeat responses can continue while rendering is broken. A host response is not proof of a usable screen.

   **Fix:** define a user-visible availability predicate and explicit failure intervals. For silent failures, record the uncertainty between last successful observation and first failed observation; do not classify ordinary heartbeat spacing as downtime. End interruption only when the relevant surface is current and usable. Specify the observation population/window and reconcile the eligibility conditions with §6’s exclusions.

3. **HIGH — Layer 1.4: one mismatching route can disable every healthy route.**

   “A host-key mismatch stops automatic connection” retains the exact failure mode A3 asked to remove. A malicious relay can promptly present a wrong certificate and prevent automatic connection through the honest provider.

   **Fix:** reject and quarantine the mismatching **candidate**, while continuing candidates that authenticate the existing pin. Never replace the pin automatically. Reserve a host-wide identity intervention for the appropriate aggregate outcome. Test a fast wrong-key relay alongside a slower correct-key route.

4. **HIGH — Layer 2.7 and phase 4: the warm-route and cold-start clocks still do not agree.**

   A completed HTTP probe does not give a newly created terminal `NWConnection` access to that probe’s TLS connection. The current [terminal transport](/Users/parvezrobin/Projects/tavi/apps/ios/Tavi/Features/Terminal/Transport/NetworkWebSocketTask.swift:78) creates its own connection and WebSocket stack. Unless v4 specifies reusable, unactivated terminal transport, promotion includes another channel setup, TLS handshake and WebSocket establishment—not merely one activation round trip.

   Phase 4 also combines “both peers cold-started” with a warm-failover deadline. Cold-started peers have neither an active session to interrupt nor a warm alternate.

   **Fix:** specify what each consumer actually retains. Separate tests for warm provider failure, cold bootstrap with a provider/DNS failure, explicit close, and abrupt interface loss. Apply the five-second attempt target to bootstrap and include every handshake in recovery measurements. Keep the absolute detection bound explicitly exempt from “every latency target is P95.”

5. **HIGH — Layers 3–4: the bulk-connection fix lacks an implementable stream-selection contract.**

   The proxy sees CONNECT destinations and encrypted bytes. An upload and `/api/host` use the same API origin; HTTP/1.1 connection pooling can reuse one TLS connection for both. The proxy cannot discover the request path inside TLS or move an established TLS stream between outer connections.

   **Fix:** assign traffic class before establishing each inner stream, with an explicit mechanism such as separate consumer pools/proxy contexts. Bind that stream to its selected outer connection for its lifetime. Verify that API uploads actually use the bulk host leg while terminal challenges use the interactive leg, including constrained uplinks and packet loss.

6. **HIGH — Layer 2.4: 150 ms of quiet can reveal a blank screen or retain the stale overlay forever.**

   A repaint can deliver a clear-screen sequence, pause for 200 ms, then deliver the content. V4 removes the overlay during that pause. Conversely, continuous output may never provide 150 ms of quiet, so a recovered terminal remains indefinitely covered and marked stale.

   Naming this a heuristic does not reconcile it with §0’s invariant.

   **Fix:** establish a qualified repaint/presentation boundary, or explicitly weaken the guarantee and define its failure behavior. Test both a split repaint with a long inter-frame pause and continuous output. Renderer queue acceptance alone must not certify presentation.

7. **HIGH — Layer 2.2 and phase 5: fencing does not establish that expired input was undelivered.**

   Input 41 can reach the PTY, lose its acknowledgment, expire locally, and then be fenced. Classifying it as “deliberately fenced” cannot replace reporting its historical delivery outcome.

   The memo also needs the host boundary at which the fence becomes effective. Closing locally cannot cancel bytes already travelling on the old route.

   **Fix:** make fencing a host-confirmed, conditional transition serialized with input acceptance, returning the final accepted watermark when available. Preserve uncertainty when that evidence is unavailable. A lost fence acknowledgment must be queryable, and fencing must not reclaim ownership from another device. The soak should classify **host-accepted / proven unaccepted / uncertain**, with fencing recorded separately.

8. **HIGH — Layers 1.3 and 4: admission-before-allocation is still incomplete.**

   An ingress Worker must consult the host’s published device list to authorize a phone. If that list lives in the host’s DO, fetching an arbitrary host ID can instantiate the object before authorization; Cloudflare creates objects on first access. Host proof of possession does not solve this phone lookup. [Cloudflare lifecycle documentation](https://developers.cloudflare.com/durable-objects/concepts/what-are-durable-objects/).

   Per-host quotas also do not bound attackers registering many independently generated host keys.

   **Fix:** specify pre-DO authorization or explicitly permit and bound unauthenticated lookup allocation. Add global registration/resource/cost limits and overload behavior. Bind signed challenges to role, host, relay and connection; do not expose device rosters through unauthenticated lookup responses.

9. **MEDIUM — Layer 3: proxy API availability is established; self-signed trust integration is not.**

   The proposed APIs exist: `URLSessionConfiguration.proxyConfigurations`, `WKWebsiteDataStore.proxyConfigurations`, and `NWParameters.PrivacyContext`. Apple documents their shared configuration model. This is a viable iOS 26 spike candidate. [Apple’s proxy integration guidance](https://developer.apple.com/videos/play/wwdc2023/10002/).

   However, naming three callbacks does not specify the self-signed trust/ATS policy requested by A3. Apple distinguishes custom trust evaluation from ATS requirements. [Manual trust evaluation](https://developer.apple.com/documentation/foundation/performing-manual-server-trust-authentication).

   **Fix:** make the spike deliver the certificate/name policy, scoped ATS configuration, and negative trust tests for all three stacks, including HMR and redirects. Require HTTPS/WSS and keep bearer credentials out of CONNECT/proxy authentication. With those conditions, the proxy can preserve the bearer-inside-TLS boundary.

10. **MEDIUM — Layer 1.4 and endpoint lifecycle: the stated bounds need failure conditions.**

    A host-pushed device-list update can be delayed indefinitely by a partition or ignored by a malicious relay. “Admission ends … seconds” is therefore only a healthy, cooperating-relay expectation. Host-enforced revocation remains the security boundary.

    Likewise, 90-day endpoint overlap does not guarantee recovery for a phone offline longer than that, and cached addresses need a freshness/replacement policy.

    **Fix:** state these bounds conditionally, define reconnect-time registry synchronization and stale-address handling, and specify the recovery path after the supported offline window.

11. **MEDIUM — Phase 4: stopping the Mac’s `tailscaled` does not reproduce the phone failure.**

    It tests an unavailable tailnet peer. It does not reproduce a wedged iOS extension, captured DNS, or a stalled exit-node route that also captures relay traffic.

    **Fix:** retain the host-daemon test but add actual phone-side failure cases. Verify relay recovery where an independent route remains reachable; where the VPN captures every route, require truthful status and a user recovery action rather than claiming transparent failover.

12. **MEDIUM — §8: ask the owner for product commitments, with the launch limitations attached.**

    Decisions 1 and 2 belong to the owner, but relay approval should include ongoing operating cost/responsibility. The launch choice should explicitly state conservative input uncertainty and that phase-6 suspension restoration is not yet included.

    Decision 3 should approve the experiment’s time/resources; “pick one now” asks a non-engineer to override missing evidence. Decision 4 should ask which customer regions matter; engineering should select relay locations from measurements. Decision 5 is a legitimate compatibility/support choice, with the consequence for existing users stated.

    “Hold until 99.99% is demonstrated” also needs an agreed evidence window and population. The memo correctly disclaims fleet evidence before a fleet; §8 must preserve that qualification.

VERDICT: NOT LOCKABLE