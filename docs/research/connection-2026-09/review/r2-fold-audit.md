All supplied research, verdict, memo, and repository paths were readable.

**V3 fixes the main direction, but several folds remain incomplete and introduce new failure modes.** Inner TLS over an ordered byte pipe is sound in principle. The unresolved parts are the pipe’s connection lifetime, iOS trust integration, relay admission, and recovery semantics.

The crosswalk covers all 41 original numbered findings. “Folded” means the objection is resolved at the planning level, including an explicit deferral. Numbers after arrows refer to the ranked findings below.

| Round-1 verdict | Folded | Partially folded → findings below |
|---|---|---|
| Fresh eyes, S1 | 7, 10, 12 | 1→6; 2→5; 3→1,3,4; 4→10; 5→8; 6→2,3,9,11; 8→7; 9→11; 11→13 |
| Networking/iOS, S2 | 6, 12, 13, 14¹ | 1→1,3; 2→6; 3→5; 4→8; 5→2,3; 7→7; 8→7,12; 9→9; 10→2,11; 11→9,10; 15→7,11 |
| Security/ops, S3 | 11, 14 | 1→1,3,4; 2→1,11; 3→2,3; 4→4; 5→5,6,11; 6→9,10; 7→8; 8→9; 9→11; 10→12; 12→5,7,12; 13→13 |

¹ The specific Noise record-size incompatibility is removed by TLS stream carriage. Relay-envelope limits still need definition.

1. **BLOCKER — §4 Layer 1.3 and Layer 4: admission prevents first pairing and return after expiry.**

   > “At pairing (and refreshed inside the channel) … a short-lived … admission capability”  
   > “The relay verifies it before allocating anything.”

   A new phone has no capability until it pairs, but cannot reach the pairing endpoint without one. A previously paired phone returning after its capability expires has the same circular dependency. This breaks the NAT-host scenario even while both providers and the host are healthy.

   The round-1 request for a **separate first-pairing admission flow is MISSED**. Phone possession proof is also missing: signing a capability containing a device id does not make its presenter possess the device’s private key.

   **Change:** define bounded admission for initial pairing and expired-capability renewal, independently of an already established inner channel. Keep the pairing redemption secret inside pinned TLS. Bind normal capabilities to the device public key and require fresh possession proof. Test first pairing and a phone returning days later with only relay access.

2. **BLOCKER — §4 Layer 3 adapter and Layer 4 protocol: the byte pipe has no defined failover lifetime.**

   > “pipes bytes into whichever outer transport is active”  
   > “TLS runs end to end between the app’s networking stack and the host”

   An established TLS connection cannot be redirected into another independently established TLS connection. Its keys, record sequence, and stream position belong to the original connection. Application-level terminal offsets do not repair missing TLS bytes below that layer. [TLS 1.3 record protection](https://www.rfc-editor.org/rfc/rfc8446.html#section-5.3).

   **Change:** choose explicitly between:
   
   - Closing affected local connections on route loss, creating fresh inner TLS connections, then resuming terminals/events at the application layer.
   - Implementing a resumable ordered stream **below TLS**, retaining both TLS endpoints and recovering every missing byte.

   The first fits the proposed session layer. It also requires explicit HTTP failure semantics: race connection establishment only; never automatically race or replay ambiguous mutations such as agent creation, Git actions, or uploads. [HTTP retry semantics](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.2.2).

   Define one relay channel per accepted local stream, channel generations, framing limits, cancellation, and teardown. Also replace “learns it from an inner close”: a dead host cannot send an authenticated TLS close. Relay failure may trigger retry through local EOF/error; only permanent authorization outcomes require host authentication.

3. **HIGH — §3 “whole surface … unchanged” and §4 Layer 3: the iOS integration is not yet a complete design.**

   > “every existing route … works unchanged”  
   > “pinning is enforced in one place”

   A raw loopback listener changes the connection destination, not automatically the logical URL, SNI, HTTP `Host`, cookie domain, or preview origin. URLSession, Network.framework, and WKWebView also have separate trust entry points; a shared verifier is possible, but installing one URLSession delegate does not secure the other stacks. [URLSession trust evaluation](https://developer.apple.com/documentation/Foundation/performing-manual-server-trust-authentication), [WebKit authentication challenges](https://developer.apple.com/documentation/webkit/wknavigationdelegate/webview(_:didreceive:completionhandler:)).

   **Change:** specify logical authorities and their mapping to loopback streams. An explicit local CONNECT/SOCKS proxy is a viable spike candidate; WebKit exposes per-data-store proxy configuration on iOS 17+. Preserve separate API/preview origins and validate the exact expected host key in each networking stack. Define self-signed trust/ATS handling rather than assuming declarative pinning accepts an otherwise untrusted certificate. [WebKit proxy API](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebsiteDataStore.h), [Apple pinning requirements](https://developer.apple.com/news/?id=g9ejcf8y).

   The spike must cover preview subresources, redirects, Secure cookies, and HMR WebSockets. Today [HostPreviewClient.swift](/Users/parvezrobin/Projects/tavi/apps/ios/Tavi/Features/Preview/HostPreviewClient.swift:30) constructs a second-port URL, and [index.ts](/Users/parvezrobin/Projects/tavi/apps/host/src/index.ts:295) still determines preview availability through Serve.

   Specify inner ALPN as HTTP/1.1 initially unless HTTP/2 support is actually implemented; existing HTTP upgrade handlers do not become HTTP/2 WebSockets automatically. [RFC 8441](https://www.rfc-editor.org/info/rfc8441/).

   Finally, `tailnet` still says “today’s `https://name.ts.net`,” whose TLS terminates at Serve. Define its host-pinned inner channel too. Reject a mismatching candidate without disabling other routes that authenticate the existing pin; never allow mutation through TLS early data.

4. **HIGH — §4 Layer 1.4: revocation does not survive “exactly as today” across the whole surface.**

   > “every inner session … is bound to a device record and rechecked as today”  
   > “invalidates admission capabilities”

   Today’s two-second check covers terminal and events WebSockets in [server.ts](/Users/parvezrobin/Projects/tavi/apps/host/src/server.ts:148). It does not provide universal TLS-session authorization. The preview door authenticates a ticket, and [PreviewRegistry.admit()](/Users/parvezrobin/Projects/tavi/apps/host/src/preview.ts:113) refreshes that ticket without consulting device revocation. Existing preview sockets are outside `keepAuthorized`.

   Nor does a host registry edit instantly invalidate an already issued capability at an independently verifying relay. Short expiry bounds exposure; it is not immediate invalidation.

   **Change:** specify host-enforced device binding for ordinary requests, standby connections, preview tickets, HMR/streaming connections, and queued input. Revocation must invalidate tickets and terminate associated streams without relay cooperation. Separately state the relay-admission revocation delay or define its invalidation protocol. Complete device-key replacement, lost-key recovery, and legacy-credential migration; host-key rotation alone does not cover these.

5. **HIGH — §4 Layer 2.2 and 2.8: expiry turns uncertainty into a false delivery verdict and can wedge sequencing.**

   > “unacked input older than the expiry is surfaced as ‘not delivered’”

   If the host accepted input and its acknowledgement was lost, this message is false and encourages duplicate manual submission. The correct outcome is **delivery uncertain**, unless the host proves nonacceptance.

   Expiry also interacts with contiguous acknowledgements: if sequence 41 expires locally while 42 remains queued, what advances the receiver past 41? Dropping 41 either leaves a permanent gap or requires a defined cancellation operation. Local expiry does not remove bytes already queued on an old route.

   **Change:** define acceptance precisely—host acceptance for PTY delivery, not application execution—and specify queue limits, conflicting-duplicate rejection, expiry enforcement, and gap resolution. On unresolved expiry, terminate/fence the input session or use an acknowledged cancellation mechanism. Preserve deduplication for the promised input-session lifetime. Test lost ACKs, delayed expired frames, conflicting retransmissions, and attachment replacement.

   The revised live-session guarantee is defensible; the expiry behavior currently contradicts it.

6. **HIGH — §4 Layer 2.1 and 2.5: generations fence callbacks but leave activation ordering and restart ordering unspecified.**

   > “explicit activation … with a host-enforced generation number”  
   > “a monotonically increasing snapshot revision”

   The memo enumerates stale callbacks but never says how stale **activation requests** are rejected. A delayed activation can otherwise arrive after a newer promotion and reclaim ownership. Likewise, after another device takes over, an old device must not automatically reclaim the terminal merely because it missed `superseded`.

   Snapshot revisions need an incarnation boundary. If revisions reset on host restart, a client retaining revision 900 can reject the restarted host’s revisions indefinitely.

   **Change:** distinguish terminal ownership epoch, logical client session, and route generation. Make activation conditional and idempotent, with an expected ownership epoch and a response that can be queried after acknowledgement loss. Fence activation requests themselves. Require explicit user takeover after ownership changes. Scope event revisions to an authenticated feed/host incarnation, and fence losing subscriptions before accepting a new incarnation.

7. **HIGH — §4 Layer 2.3, 2.4 and 2.8: screen recovery still confuses bytes, pictures, and emulator state.**

   > “waits for the first output after `ready` or a short timeout”  
   > “epoch, acked offset, geometry, the frame the offset corresponds to”

   The first output can be only a clear-screen escape, half an escape sequence, or the beginning of a multi-frame repaint. A timeout proves nothing about rendering. Either condition can uncover a blank or incomplete surface.

   A matching picture and offset also cannot restore Ghostty’s parser, modes, alternate buffer, or pending bytes after process death. This remains true even if the checkpoint is called coherent.

   **Change:** retain stale presentation until reconstruction has a qualified completion boundary and the renderer has processed it. A timeout keeps the display stale and reports recovery trouble; it must not certify repaint completion. After process/renderer loss, always request a fresh repaint unless a real emulator-state serializer has been demonstrated.

   The round-1 geometry finding is **MISSED**: [attachment.ts](/Users/parvezrobin/Projects/tavi/apps/host/src/attachment.ts:188) still hands geometry back after eight seconds. Define geometry-version compatibility and force repaint where replay crosses incompatible geometry. Name an eviction policy alongside the host-wide retention budget.

8. **HIGH — §0, §4 Layer 2.6–2.7 and phase 4: detection and exit-test clocks still disagree.**

   > “challenge every 5 s, dead after two misses”  
   > “kill Cloudflare … live within 2 s”

   Dropping Cloudflare packets creates a silent failure. It cannot reliably satisfy a two-second fault-to-live gate with a detector allowed ten seconds. “Two misses” also lacks a precise deadline: the existing tick-counting algorithm would produce approximately 10–15 seconds at a five-second interval.

   The adapter adds another trap: the inner `NWConnection` sees a healthy loopback path. Its viability or `betterPath` cannot represent the outer Wi-Fi/LTE connection.

   **Change:** define absolute deadlines covering queueing, send completion, and response; identify the first-miss versus second-miss actions. Obtain path events from the outer transport. Measure fault→detection and detection→render separately, and rewrite phase 4 accordingly. Qualify Wi-Fi→LTE results on whether an alternate remains usable; both warm sockets may die together. Include a host-leg blackhole while outer WebSocket pongs continue.

9. **HIGH — §0 and §4 Layer 3: rendezvous works for a fixed endpoint set, but bootstrap independence remains partial.**

   > “endpoints cached … so a cold start with empty DNS caches still has somewhere to go”  
   > “whichever of ≤ 4 relays the host is registered on”

   Cached `wss://` hostnames still require DNS. Separate zones can share the same DNS provider and failure domain. Parallel dialing solves finding a registration **inside the cached set**; it does not define endpoint replacement, retirement, or a host relocating outside that set.

   **Change:** specify independently operated resolution/bootstrap paths, preserving TLS hostname validation, and authenticated endpoint updates with overlap long enough for offline phones. Define duplicate host registration, registration generations, stale registrations, host replacement, and regional relocation. Test both peers cold-starting while one provider and its DNS dependencies are unavailable.

   Deterministic DO naming and simultaneous registration with both providers are correctly folded. They do not by themselves finish these lifecycle cases.

10. **HIGH — §0: the SLIs are separated, but their remaining definitions can conceal the exact failure being addressed.**

    > “Time a foreground session shows anything other than live state”  
    > “≤ 4 min per 100 session-hours”

    If this measures the displayed connection label, a frozen screen still labelled Live accrues no interruption until detection. That rewards late detection. The interruption interval must include the silent portion, with its measurement uncertainty stated.

    Four minutes per 100 hours permits **99.9333% foreground availability**. Four-nines foreground availability permits **36 seconds per 100 hours**. Separate denominators are now correct, but this remains a materially weaker session target requiring an explicit owner decision.

    Eligibility is also incomplete: a running host with an uplink can have a wedged herdr or no relay reachable by both peers. Those cases are neither consistently included nor excluded.

    **Change:** define the user-attempt unit, observation window/population, interruption start and end, unknown attribution, and common-route eligibility. State percentiles for every latency target. Measure authenticated rendering progress rather than UI labels, and explain how representative release data establishes each target.

11. **HIGH — §5 and §6: the reordered phases still omit required safety and operating gates.**

    > “Phases 1–4 are the product change”  
    > “snapshot revisions” in phase 5  
    > “Operations before 10 k users”

    The sequence is substantially improved. However, cross-route snapshot safety arrives after promotion, and phases 3–4 never explicitly preserve today’s no-replay/uncertainty behavior before numbered input ships. A successful MARK soak does not exercise the ordering defects identified in round 1.

    **Change:** before shipping promotion, gate ownership, event ordering, and conservative input behavior. Add real-type tests for a slow peer, never-returning send, close mid-await, delayed activation, lost ACK, takeover, restart, and mixed protocol versions. Phase 5’s “zero lost” test must distinguish proven delivery, deliberate expiry, and uncertainty.

    Make relay protocol and operating readiness prerequisites to the first managed release: bounded global admission/resources, stream cancellation, hibernation recovery of flow-control state, overload behavior, reconnect jitter, VPS draining, mixed-version rollback, full-provider capacity, and an exercised reconnect storm. Channel maps alone do not restore all flow-control state after memory is discarded. [Cloudflare hibernation behavior](https://developers.cloudflare.com/durable-objects/best-practices/websockets/).

    Physical gates should include immediate suspension/process death, NAT64, broken-AAAA fallback, and an enabled but stalled VPN—not just a disabled VPN.

12. **MEDIUM — §4 Layer 2.8, Layer 4 metadata and §6 privacy: disclosures and display protection remain partial.**

    > “Relay operators can observe connection metadata”  
    > “shown only behind the app’s existing access gate”

    The wording and no-managed-relay choice are correct. They do not resolve round 1’s questions about actual provider/access-log fields, retention, deletion, access controls, and telemetry consent. Protected files and an access gate also do not specify app-switcher snapshots or locking while an already visible terminal is backgrounded.

    **Change:** define the metadata lifecycle and screen-redaction behavior. Verify no-managed-relay mode makes no managed registration, admission, probe, or telemetry contact from either peer. Keep these as concrete release criteria.

13. **MEDIUM — §6 money and phase 1(c): the corrected estimates still model the old workload.**

    > “2,000 concurrent sessions, 2 h/day … ≈ $39/month”

    Qualification fixes the misleading universal price. The proposed design now includes always-connected host registrations on both providers, challenged standby routes, multiple inner connections, and previews/uploads. The research’s session-only model does not cover those additions.

    **Change:** make phase 1(c) produce a reproducible model using host connection-hours, active and standby message counts, measured billable execution duration, both traffic directions, regional egress, and full failover load. Separate compute from bandwidth and operating costs.

VERDICT: NOT LOCKABLE