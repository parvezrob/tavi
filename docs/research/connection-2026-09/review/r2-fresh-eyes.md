All supplied paths were readable. **V3 supports starting bounded work, but it is not ready to lock as the connection architecture.**

The strongest case against **relay-first with inner TLS** is that Tavi would own a new multiplexed transport, an iOS proxy integration, admission and renewal, and recovery across three networking stacks. Iroh already supplies authenticated streams and path migration; its value includes latency and recovery, beyond bandwidth. Its documented [multipath design](https://www.iroh.computer/blog/iroh-0-96-0-the-quic-multipaths-to-1-0) makes this a serious alternative. Conversely, binding reliability and suspension behavior remain unproven for Tavi. **Inner TLS survives as a candidate; committing to the custom relay before a comparative spike does not.**

The strongest case against **two relay providers** is operational complexity and correlated failure: both still depend on the same phone, host, transport code, credential lifecycle, and potentially DNS infrastructure. Extra sockets also consume resources without providing a second radio path. Nevertheless, a Mac behind NAT needs a second independently reachable outbound service if provider failure must be transparent. Optional direct/Tailscale routes cannot provide that universally. **This choice survives**, provided operations and common-cause testing are launch requirements.

Phase 0 is small enough to start tomorrow: truthful status, retained visible content, targeted reproduction, and logging. Phase 1 can start tomorrow as a time-boxed experiment; its current matrix is too broad to represent completed qualification in one week. The owner can understand the intended product reversal, but cannot yet know which transport wins the experiment, what “warm” buys, or which reliability target he is accepting.

Ranked findings:

1. **BLOCKER — §4 Layer 1.3: admission creates two connection deadlocks.**

   Quote: “At pairing (and refreshed inside the channel) … a short-lived … admission capability”; “The relay verifies it before allocating anything.”

   A first-time phone cannot reach the pairing exchange because it has no admission capability. A previously paired phone returning after its capability expires cannot establish the channel needed to refresh it. This breaks ordinary remote onboarding and next-day use for relay-only customers.

   **Change:** define separate bounded admission flows for first pairing and expired-capability renewal. Bind renewal to proof of the paired device’s private key and host authorization. Test first pairing over LTE, expiration during suspension, host restart, and a revoked device attempting renewal. Short lifetime also does not itself invalidate an already-issued capability immediately; distinguish host revocation from relay admission expiry.

2. **HIGH — §4 Layers 3–4: choose the TLS recovery boundary explicitly.**

   Quote: the adapter “pipes bytes into whichever outer transport is active”; when the host leg drops, “every channel is closed immediately.”

   An established TLS stream cannot simply continue through an unrelated replacement TLS connection. Either its original endpoints and exact ordered byte stream survive beneath TLS, or its consumers must reconnect. TLS record authentication depends on connection-specific keys and record sequence. [TLS 1.3 specification](https://www.rfc-editor.org/rfc/rfc8446.html#section-5.3).

   **Change:** specify channel teardown and fresh inner connections, followed by application-level recovery—or explicitly design a resumable tunnel beneath TLS. For the former, define recovery for HTTP mutations as well as terminals. Losing the response after creating an agent, uploading a file, or committing must not trigger blind resubmission. Use operation reconciliation/idempotency where supported and explicit uncertainty otherwise. A warm HTTP probe does not automatically provide a reusable terminal WebSocket.

3. **HIGH — §3 and §5 phase 1(a): the whole-surface claim exceeds the proposed spike.**

   Quote: “every existing route … works unchanged”; spike: “with `URLSession` and `NWConnection`.”

   The preview runs in **`WKWebView`**, with its own networking, secure cookie, and origin handling. Its current [implementation](/Users/parvezrobin/Projects/tavi/apps/ios/Tavi/Features/Preview/PreviewSheet.swift:467) has neither proxy configuration nor custom server-trust handling. A transparent byte adapter cannot enforce TLS pinning centrally if separate consumer stacks terminate TLS.

   This is not inherently impossible: Apple describes a [local proxy approach for WebKit](https://developer.apple.com/forums/thread/795547), and Node supports [TLS over a Duplex stream](https://nodejs.org/api/tls.html). But feasibility is not established by a terminal demo.

   **Change:** include WebKit HTML, assets, redirects, secure cookies, and hot-reload WebSockets in the first spike. Specify logical hostnames, certificate validation, and separation of API and preview origins. Also reconcile the `tailnet` row’s “today’s HTTPS” with host-key pinning: today TLS terminates at Serve.

4. **HIGH — §4 Layer 2.8: expired unacknowledged input is not necessarily undelivered.**

   Quote: “unacked input older than the expiry is surfaced as ‘not delivered’.”

   The host can accept a command and lose the acknowledgement. Expiry changes replay policy; it does not establish whether execution happened. Telling the user “not delivered” encourages a duplicate submission.

   Expiry also interacts with contiguous sequencing: dropping sequence 12 while continuing with 13 needs an explicit resolution, not an unexplained gap.

   **Change:** distinguish never-submitted input from submitted-but-unconfirmed input. Report the latter as **delivery uncertain**, reconcile against the retained host ledger when possible, and define cancellation/fencing or input-session replacement when unresolved expired sequences prevent progress. Test lost acknowledgements followed by expiry and delayed old-route arrival.

5. **HIGH — §4 Layer 2.4/2.8: the screen-recovery mechanism still cannot establish a correct restored screen.**

   Quotes: “first output after `ready` or a short timeout”; checkpoint contains “epoch, acked offset, geometry, the frame.”

   The first output chunk may contain only a clear-screen escape or part of a repaint. A timeout proves nothing about completion. Separately, even pixels matching an offset do not contain Ghostty’s parser, cursor, modes, alternate screen, or scrollback state; they cannot support byte resume after process death.

   There is another omitted boundary: [attachment.ts](/Users/parvezrobin/Projects/tavi/apps/host/src/attachment.ts:188) hands geometry back to the desktop after eight seconds. A longer ring does not make bytes produced under another geometry safely replayable into the phone’s unchanged grid.

   **Change:** keep cached pixels as a stale overlay until an authoritative repaint has been processed and presented. Introduce a measurable repaint boundary, or explicitly weaken the invariant. After renderer loss, request a fresh repaint unless complete emulator restoration is demonstrated. Invalidate byte resume or carry ordered geometry changes when dimensions change.

6. **HIGH — §0, Layer 2.7 and phase 4: the roaming exit test assumes a warm path the design does not maintain.**

   Quote: “Wi-Fi→LTE mid-typing: live ≤ 1 s”; “one alternate stays established.”

   Two provider connections on Wi-Fi are both cold after Wi-Fi disappears. V3 acknowledges this, but its phase-4 exit test remains unconditional. Apple’s [better-path callback](https://developer.apple.com/documentation/network/nwconnection/betterpathupdatehandler) advises establishing a replacement connection; it does not migrate TCP or guarantee an already-working cellular connection.

   From Dhaka to Virginia, repeated outer establishment, inner TLS, application activation, replay, and rendering round trips materially affect the result.

   **Change:** distinguish provider failure on an unchanged network, overlap between interfaces, and abrupt loss requiring cold establishment. Define exactly which layers a “warm” standby has completed. Give each case a percentile and measurement start point. Add absolute challenge deadlines covering blocked sends; “every five seconds, two misses” alone does not define a ten-second maximum.

7. **HIGH — §4 Layer 4: per-channel flow control does not eliminate shared TCP stalls.**

   Quote: “one WebSocket per provider”; flow control “so an upload cannot starve a terminal.”

   Fair scheduling limits application queue starvation. It cannot remove TCP head-of-line blocking across channels already multiplexed onto the host leg. A missing segment can delay terminal input, output, or challenges behind unrelated bulk traffic.

   **Change:** include terminal latency and false-failover measurements during a maximum upload and busy preview, with asymmetric bandwidth and packet loss. Bound aggregate bytes already handed to the socket, prioritize interactive traffic, and evaluate a separate bulk connection or independent transport streams if needed. Qualify Europe→Virginia and Dhaka LTE→Virginia, not only Dhaka→home Mac. The research’s terminal-only bandwidth argument does not cover Tavi’s full surface.

8. **HIGH — §0 and Layer 3: cached endpoint names do not establish cold-start independence.**

   Quote: “endpoints cached … so a cold start with empty DNS caches still has somewhere to go.”

   Caching `wss://relay.example` does not resolve it when DNS fails. Separate zones can still share authoritative infrastructure, and phone-side VPN DNS can affect both. Endpoint changes also need a recovery path for a phone offline throughout the migration.

   **Change:** specify independent DNS operation and an authenticated endpoint-update policy with overlap. If address caching is the bootstrap mechanism, preserve hostname/SNI verification and define address expiry and replacement. Test both peers cold-starting with one provider unavailable, DNS unavailable or intercepted, and stale endpoint configuration. Merely blocking Cloudflare IPs while existing alternate sockets remain open does not establish this property.

9. **HIGH — §3 and phase 1(b): the iroh gate prejudges the central decision.**

   Quote: “adopted as a route only if … > 80 % direct on LTE.”

   The custom relay supplies **0% direct connectivity**. Rejecting iroh at 79% says nothing about which implementation delivers safer recovery, lower maintenance, or better latency. “Only as a route” also prevents the experiment from selecting iroh as the principal transport and avoiding part of the custom relay system.

   **Change:** compare both candidates against the same full-surface workload and failure matrix: successful connection, recovery tails, cancellation, suspension, CPU/RAM/battery, packaging, and operation through independently hosted relays. Treat direct percentage and download size as measured tradeoffs with justified budgets. End phase 1 with an explicit selection decision; a failed adapter spike must not silently authorize a substantially different Noise architecture.

10. **MEDIUM — §0, §5 and §6: the owner still lacks a concrete launch bargain.**

    Quotes: “≤ 4 min per 100 session-hours”; “Phases 1–4 are the product change”; “Operations before 10 k users.”

    Four minutes per 100 hours permits **99.933% foreground time availability**, versus 36 seconds for 99.99%. Separate attempt and time SLIs are correct, but the owner must explicitly accept those different targets. Phases 1–4 also precede the promised input replay behavior and suspension restoration. Operational ownership cannot wait until an unspecified point below 10,000 users.

    **Change:** state the launch gate, its accepted interruption budget, interim input behavior, and named operational responsibility before the first managed-relay release. Time-box phase 1 to feasibility evidence and label broader qualification separately. The repo targets [iOS 26](/Users/parvezrobin/Projects/tavi/apps/ios/Tavi.xcodeproj/project.pbxproj:352); clarify whether “iOS 17–26” means a standalone adapter experiment or a new product-support commitment. Replace §6’s fixed “20–30 s” suspension claim with the research’s actual conclusion: background execution time is finite and not guaranteed.

VERDICT: NOT APPROVED