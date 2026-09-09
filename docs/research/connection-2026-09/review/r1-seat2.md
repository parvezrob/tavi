I read all six research files and the requested repository sources. Relay-first is defensible; the memo’s session ownership, authentication, and recovery guarantees are not ready for approval.

The §2 baseline is mostly accurate, with important qualifications:

| Claim | Verified repository behavior |
|---|---|
| 120 s retention; 1 MiB ring | Exact defaults: `RESUME_BUFFER_BYTES = 1024 * 1024` and `DETACHED_RETENTION_MS = 120_000` in [attachment.ts:3](/Users/parvezrobin/Projects/tavi/apps/host/src/attachment.ts:3). Retention starts when the host releases the client. |
| Epoch and byte-offset resume | Correct. [protocol/README.md:457](/Users/parvezrobin/Projects/tavi/protocol/README.md:457) defines the offset as bytes **accepted into the renderer’s ordered queue**, not rendered pixels. A miss already creates a fresh attachment so **herdr repaints the pane**; [terminal-bridge.ts:83](/Users/parvezrobin/Projects/tavi/apps/host/src/terminal-bridge.ts:83) implements this. |
| 64 KiB frames | Correct: a nine-byte header plus at most 65,527 output bytes, [protocol.ts:4](/Users/parvezrobin/Projects/tavi/apps/host/src/protocol.ts:4). |
| Events snapshots and heartbeat | Correct. Subscribers immediately receive the retained snapshot in [herdr-events.ts:118](/Users/parvezrobin/Projects/tavi/apps/host/src/herdr-events.ts:118). The 15 s heartbeat is **events-only**, with termination **30–45 s** after the last pong; [socket-heartbeat.ts:4](/Users/parvezrobin/Projects/tavi/apps/host/src/socket-heartbeat.ts:4), [protocol/README.md:346](/Users/parvezrobin/Projects/tavi/protocol/README.md:346). |
| NWConnection and path observer | Correct: [NetworkWebSocketTask.swift:78](/Users/parvezrobin/Projects/tavi/apps/ios/Tavi/Features/Terminal/Transport/NetworkWebSocketTask.swift:78), [NetworkPathObserver.swift:20](/Users/parvezrobin/Projects/tavi/apps/ios/Tavi/Features/Terminal/Transport/NetworkPathObserver.swift:20). The observer reports default-path satisfaction and the first available interface; it does not prove host reachability. |
| “10 s dial budget” | Incomplete: **10 s TCP**, **12 s overall terminal-ready deadline**; [ReconnectPolicy.swift:7](/Users/parvezrobin/Projects/tavi/apps/ios/Tavi/Features/Terminal/Transport/ReconnectPolicy.swift:7). Terminal heartbeat is already **10 s interval, 5 s send, 5 s pong, 2 s handover challenge**; [TerminalTiming.swift:16](/Users/parvezrobin/Projects/tavi/apps/ios/Tavi/Features/Terminal/Transport/TerminalTiming.swift:16). |
| Pairing and revocation | Per-device bearer credentials and the 2 s recheck exist; [server.ts:142](/Users/parvezrobin/Projects/tavi/apps/host/src/server.ts:142). The fingerprint is **not an existing cryptographic host-key pin**, as detailed below. |

Ranked findings:

1. **BLOCKER — §4 Layer 1.7: “host static key from the QR fingerprint.”**

   The existing identity is 32 random bytes; its displayed fingerprint is the first 16 hexadecimal characters of SHA-256 over those bytes. No asymmetric public key is supplied or pinned. Pairing compares a fingerprint string returned inside HTTPS JSON. See [pairing.ts:74](/Users/parvezrobin/Projects/tavi/apps/host/src/pairing.ts:74), [pairing.ts:119](/Users/parvezrobin/Projects/tavi/apps/host/src/pairing.ts:119), and [HostPairing.swift:68](/Users/parvezrobin/Projects/tavi/apps/ios/Tavi/Features/Pairing/HostPairing.swift:68). The host stores only hashes of device credentials, so those credentials are not already a shared Noise PSK either.

   **Change:** Specify a versioned pairing protocol that authenticates a real host public key before sending the pairing secret or bearer credential through the relay. Migrate existing phones through the trusted existing connection or a new QR scan.

   Noise IK is reasonable **if device public keys become the authorization identity**, including revocation and rotation. Otherwise, first evaluate pinned end-to-end TLS 1.3 plus the existing bearer credential; the TLS-over-relay adapter needs a feasibility spike. A vetted Noise NK implementation followed by bearer authentication is another smaller identity change. Whichever is chosen, keep separate cipher states per route and prohibit command execution from replayable handshake/early-data payloads. [Noise specification](https://noiseprotocol.org/noise.html).

2. **BLOCKER — §4 Layer 2: “keeps the first … delivers a snapshot, keeps one alternate warm.”**

   Every terminal attachment currently **claims ownership immediately**. The next attachment supersedes it—even a compatible resume—and the losing client stops automatic reconnection. See [terminal-bridge.ts:183](/Users/parvezrobin/Projects/tavi/apps/host/src/terminal-bridge.ts:183) and [attachment.ts:176](/Users/parvezrobin/Projects/tavi/apps/host/src/attachment.ts:176). A slower racing connection can therefore evict the selected winner. On fresh connects, it can also replace the attachment and epoch.

   **Change:** Separate authenticated route establishment from terminal attachment. Warm routes must not claim or resize the PTY. Define a logical client session, an explicit activation operation, and a host-enforced generation that rejects the old route’s late input, resize, output, and close callbacks.

   “Snapshots are idempotent” does not solve cross-route ordering: an older full events snapshot can overwrite a newer one. `asOf` is optional staleness metadata, not a sequence number. Fence old routes or add a snapshot revision.

3. **BLOCKER — §4 Layer 1.2: “Exactly-once across any reconnect.”**

   Sequence numbers solve retransmission only while the receiver retains the relevant deduplication state and ordering. The memo leaves that state’s identity and lifetime undefined. An output-ring miss currently replaces the attachment even while the host remains up. Replaying unacknowledged input into its replacement could repeat an already executed command.

   Further, `terminal.write()` is not an acknowledgement from the target application; [attachment.ts:227](/Users/parvezrobin/Projects/tavi/apps/host/src/attachment.ts:227) merely forwards the bytes. A host crash between PTY delivery and recording the acknowledgement cannot be made atomic with an arbitrary shell.

   **Change:** Promise ordered, duplicate-free delivery across route changes **within a defined live input-session epoch**. Acknowledge the highest **contiguous** accepted sequence, reject conflicting duplicate payloads, bound queues, and retain deduplication independently of output retention. On lost input-session state, report uncertainty and require explicit resubmission.

   Negotiate this capability before replaying anything. Existing v2 parsers ignore extra input fields and would execute retransmissions again; [protocol.ts:25](/Users/parvezrobin/Projects/tavi/apps/host/src/protocol.ts:25).

4. **HIGH — §4 Layers 2–3: “Heartbeat 5 s … two misses = dead (10 s)” and “live screen back within 1 s.”**

   These targets conflict. Even accepting the proposed ten-second detector, a warm alternate cannot remove those ten seconds. Copying the current host tick algorithm at five-second intervals actually produces roughly **10–15 seconds** from the last pong.

   There is also a new liveness trap: Cloudflare automatically answers WebSocket control pings without invoking the DO handler. Such a pong proves the phone-to-Cloudflare leg, not the host connection. The existing terminal JSON ping can traverse the encrypted session; the events watchdog’s WebSocket control ping cannot simply retain its present meaning. [Cloudflare WebSocket handling](https://developers.cloudflare.com/durable-objects/best-practices/websockets/).

   **Change:** Require authenticated, end-to-end application challenges with deadlines covering both send and response. Measure fault-to-detection separately from detection-to-restored-output. Either relax the silent-stall SLO or design and measure a faster detector. Test with the host-facing relay leg blackholed while Cloudflare keeps answering control pings.

5. **HIGH — §4 Layer 3 and §5 Phase 1: “one WebSocket” and “phone with no Tailscale … reaches a Mac.”**

   The proposed relay describes terminal frames but leaves the rest of Tavi’s transport undefined. Pairing, host discovery, agent creation, Files, Source Control, and preview management use HTTP routes; [server.ts:281](/Users/parvezrobin/Projects/tavi/apps/host/src/server.ts:281). Even terminal handshake-error classification makes a separate HTTPS request; [TerminalWebSocketClient.swift:37](/Users/parvezrobin/Projects/tavi/apps/ios/Tavi/Features/Terminal/Transport/TerminalWebSocketClient.swift:37).

   **Change:** Specify whether the encrypted connection tunnels existing HTTP/WebSocket traffic or carries a versioned multiplexed RPC protocol. Include request cancellation, error classification, stream isolation, and preview support explicitly. Mutating HTTP requests must not be blindly raced or replayed.

   Phase 1’s exit test should perform pairing, list agents, open a terminal, and execute an API action with Tailscale absent. Otherwise it proves a terminal prototype, not a usable Tavi route.

6. **HIGH — §4 Layer 1.3: “echoAck … PTY ≥ 50 ms” and “70 %+ … instantly at any RTT.”**

   Prediction can work over TCP. The missing piece is a precise relationship between the prediction and the authoritative terminal state—not UDP itself.

   Mosh’s 50 ms value is a heuristic about when application effects **ought** to be reflected in its synchronized screen. It is not proof that input was consumed or echoed. Its results came from specific recorded workloads, and a new prediction epoch initially waits for confirmation. Neither result establishes a universal 30 ms guarantee. [Mosh paper](https://mosh.org/mosh-paper.pdf).

   Tavi adds another uncertainty: its PTY runs `herdr agent attach`, not the target application directly. Delays can occur beyond that PTY. Attaching today’s `echoAck` to previously buffered output would associate an acknowledgement with the wrong screen. Sending it only with output also fails when there is no output.

   **Change:** Initially retain authoritative terminal rendering and use the local composer for immediate text feedback. For a later prediction experiment, use a separate visual overlay, never inject predictions into the authoritative emulator or output offsets. Bind confirmation markers to the input epoch, sequence, output epoch, exact output boundary, and geometry version; markers must also travel without output.

   Conservatively disable prediction across alternate-screen transitions, arbitrary Claude Code/TUI redraws, cursor/mode changes, bracketed paste, and IME marked text. IME composition belongs locally until committed; paste must preserve its delimiters and ordering. Reject predictions on mismatch and re-earn confidence. Measure accuracy and latency by application before making product promises.

7. **HIGH — §4 Layer 1.1: “Add a screen snapshot (serialized emulator state).”**

   The Node attachment holds output bytes, not an emulator. A resumable emulator checkpoint includes parser state, partially received escape sequences/UTF-8, both screen buffers, cursor, modes, margins, geometry, and potentially scrollback. A picture or visible text grid is insufficient.

   The memo also omits an existing recovery mechanism: herdr already repaints after a resume miss. Adding another terminal-state implementation before investigating that path creates a substantial compatibility surface.

   **Change:** First fix the kept-frame behavior and qualify the existing fresh-attach repaint. Keep stale presentation visible while reconstruction occurs; `ready` alone does not prove a complete repaint. If checkpoints remain necessary, name their producer and define an atomic `(epoch, output offset, geometry, emulator state)` boundary with snapshot-then-tail ordering and version compatibility.

8. **HIGH — §4 Layer 1.6: “snapshots … on background” and resumes “before any UI redraw.”**

   A background callback is not a durable-save guarantee. iOS may refuse extra runtime, expire it immediately, or terminate the process before the final checkpoint. Apple explicitly requires operation without guaranteed background-task time. [Apple background-task guidance](https://developer.apple.com/forums/thread/85066/).

   Saving the latest accepted byte offset alongside an older frame is particularly unsafe: the host then skips output absent from the restored emulator.

   **Change:** Checkpoint coherently during foreground operation, with background saving as a final best effort. Restore cached presentation promptly and reconnect asynchronously; never block the first redraw on networking. If exact emulator state is unavailable, show the cached image as stale and request a fresh repaint without claiming byte resume.

   Protect persisted terminal content and unacknowledged input with appropriate file protection, backup exclusion, expiry, and deletion on unpair. Live Activities can display session status; they do not provide a general background terminal-socket execution entitlement. [ActivityKit documentation](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities?changes=_6).

9. **HIGH — §4 Layer 3: “No control plane” and “host choosing by RTT.”**

   A public key identifies a host; it does not locate its current connection on independently operated VPSes. If the host chooses Singapore and the phone reaches Virginia, there is no path unless registration discovery, inter-relay forwarding, or multi-registration exists. `/api/host` cannot bootstrap a route while that host is unreachable.

   Cloudflare can solve its own lookup deterministically: every ingress Worker maps the canonical host identity to the same DO namespace/name. That does not solve VPS rendezvous or provider failover.

   **Change:** Define a small explicit registration/rendezvous protocol. Persist authenticated relay endpoints on both peers during pairing, specify region changes, and have the host maintain connections to both providers before claiming immediate failover. Document the remaining control dependencies rather than declaring them absent.

10. **HIGH — §4 Layer 3: “opaque frames … no parsing, no storage … ~500 lines.”**

    A host connection serving multiple phones needs channel identifiers and routing metadata. Registration needs proof of private-key possession; merely presenting a public key is not authentication. Public-key rate limits alone are bypassable by creating new keys.

    Hibernation preserves healthy WebSockets but destroys ordinary in-memory maps. Reconstruct authenticated roles, channel mappings, and connection generations from attachments. Forward each channel in order; asynchronous handlers can interleave, and independently reconnected sockets have no shared ordering guarantee. Hibernation itself is not a disconnect, whereas deployment/runtime shutdown terminates WebSockets. [Hibernation example](https://developers.cloudflare.com/durable-objects/examples/websocket-hibernation-server/), [DO concurrency rules](https://developers.cloudflare.com/durable-objects/best-practices/rules-of-durable-objects/), [shutdown behavior](https://developers.cloudflare.com/durable-objects/concepts/durable-object-lifecycle/).

    **Change:** Specify bounded per-channel flow control, authorization, stale-connection fencing, overload behavior, and peer-disconnect propagation. If the host leg disappears, invalidate affected phone channels immediately. Share the forwarding core with Node, with distinct platform lifecycle adapters. Remove the line-count estimate until these behaviors are accounted for.

11. **HIGH — §0 and §5: “two independent routes … for the 99.99 % math.”**

    Provider count does not establish end-to-end availability. Shared DNS, certificate renewal, registration, simultaneous releases, client bugs, and host connectivity remain correlated dependencies. A stalled Tailscale exit node can also capture public relay traffic; tailnet DNS overrides can affect relay resolution. [Exit-node routing](https://tailscale.com/docs/features/exit-nodes), [Tailscale DNS](https://tailscale.com/docs/reference/dns-in-tailscale).

    Additionally, 99.99% successful connection attempts is not equivalent to 4.3 minutes of monthly downtime. “Any internet” admits networks that reach a public probe but block WebSockets or the host’s ISP.

    **Change:** Define separate foreground-session availability and connection-attempt SLIs, eligibility, deadlines, and measured exclusions. Exercise provider failure with cold DNS and both peers reconnecting, plus a stalled VPN that remains enabled. Move the second provider ahead of predictive echo if provider independence is required for launch.

    The existing soak is not evidence for four nines: [CONNECTION_111_PLAN.md:443](/Users/parvezrobin/Projects/tavi/docs/CONNECTION_111_PLAN.md:443) explicitly limits it to application recovery on a good underlying link.

12. **HIGH — §5 Phase 0: “public-endpoint probe … → tunnelStalled.”**

    Public internet success plus host failure cannot distinguish phone VPN failure, host-side Tailscale failure, ACL changes, DNS failure, host sleep, or host ISP failure. Host-side route information cannot resolve that ambiguity when no route reaches the host.

    The incident strongly supports a phone-side Tailscale problem, but its report explicitly leaves the DERP failure unexplained; [incident README:11](/Users/parvezrobin/Projects/tavi/docs/history/2026-09-09-tailscale-stall/README.md:11). `udp=false` and low extension memory do not prove the particular ReceiveIPv4/ENOTCONN mechanism.

    **Change:** Say “Internet reachable; this computer is unreachable through Tailscale,” with a suggested recovery action. If an authenticated alternate reaches the same host, say the Tailscale route failed. Reserve causal diagnoses for stronger evidence. Turning Tailscale off does not reproduce an extension that remains enabled but silently stalls.

13. **MEDIUM — §3 and §7.3: “348-city edge … 20–50 ms” and “RTT is the same either way.”**

    Phone-to-edge latency is only one segment. The full path includes the phone’s edge-to-DO journey and the DO-to-host leg. Host-near and phone-near placement are approximately equivalent only under idealized symmetric routing; actual peering, detours, processing, and queues matter.

    DO placement is near the initial request, not necessarily at that colo; location hints are best effort and currently do not relocate an existing object. A phone or unauthenticated request arriving first can defeat the assumed host-first placement. [Cloudflare placement documentation](https://developers.cloudflare.com/durable-objects/reference/data-location/).

    **Change:** Authenticate host registration before creating its routing object, specify deterministic lookup and placement policy, and measure complete input-to-output RTT across the proposed geography matrix. Predictive echo does not hide delayed control keys, scrolling, permissions, or screen updates.

14. **MEDIUM — §4 Layer 3: “64 KiB max” with Noise and Durable Objects.**

    Cloudflare’s current **32 MiB received-message limit** comfortably accommodates Tavi frames. The actual incompatibility is Noise: its maximum ciphertext message is **65,535 bytes**, including a 16-byte authentication tag. An existing maximum-size Tavi frame is already **65,536 bytes**, before encryption or relay headers. [Cloudflare limits](https://developers.cloudflare.com/durable-objects/platform/limits/), [Noise message format](https://noiseprotocol.org/noise.html#message-format).

    **Change:** Define separate application-frame, encryption-record, and relay-envelope limits. Fragment or reduce payloads, account for every header/tag, and bound reassembly. Do not treat Cloudflare’s larger ceiling as the application’s safety limit.

15. **MEDIUM — §4 Layer 1.1: “30 min … 4 MiB”; Layer 2: “Dual-stack hostnames only.”**

    Four MiB holds only about **14 minutes at 5 KiB/s**, and much less during output bursts. Thirty-minute retention is attachment lifetime, not thirty-minute replay coverage. It also retains PTYs and processing work, not just the ring. The existing attachment changes back to desktop geometry after an eight-second detach grace; [attachment.ts:188](/Users/parvezrobin/Projects/tavi/apps/host/src/attachment.ts:188). More retention does not fix geometry-dependent replay.

    **Change:** Set host-wide memory/attachment limits, measure output distributions, and define eviction and geometry recovery.

    Separately, dual-stack service is desirable, but an A-only public hostname can work through DNS64/NAT64; Apple does not require every origin to publish AAAA. Test native IPv6, NAT64, broken AAAA fallback, and system resolution. [Apple IPv6 guidance](https://developer.apple.com/support/ipv6/). `NWConnection` make-before-break is feasible on iOS 17–26, but requires a new connection and application handover; it is not TCP migration or guaranteed path diversity. [Apple API guidance](https://developer.apple.com/documentation/network/nwconnection/betterpathupdatehandler?changes=_6). This repository currently targets iOS 26.

VERDICT: NOT APPROVED