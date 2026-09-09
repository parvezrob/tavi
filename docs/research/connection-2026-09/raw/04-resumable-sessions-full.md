<!-- verbatim final report of the research agent, 2026-09-09; condensed version in ../04-resumable-sessions.md -->

I have the primary sources. Findings below.

---

# Resumable remote-terminal protocols: facts

## 1. Mosh / State Synchronization Protocol (SSP)

Primary sources: [USENIX ATC '12 paper](https://www.usenix.org/system/files/conference/atc12/atc12-final32.pdf) (fetched and read in full via https://mosh.org/mosh-paper.pdf), and upstream C++ source (`mobile-shell/mosh`).

**Model.** SSP synchronizes *abstract state objects*, not byte streams. Two independent SSP instances run: client→server the object is *the history of the user's input*; server→client it is *the contents of the terminal window*. Two layers: a **datagram layer** (prepends an incrementing sequence number, encrypts with AES-128-OCB, estimates SRTT/RTTVAR, tracks the client's current public IP) and a **transport layer** that sends an **Instruction** — "a self-contained message listing the source and target states and the binary 'diff' between them". The diff is computed by the object: for input it is *every intervening keystroke* (so no keystroke is lost); for the screen it is "only the minimal message that transforms the client's frame to the current one".

**Idempotence, not replay caches.** "Each datagram sent to the remote site represents an idempotent operation at the recipient — a 'diff' between a numbered source and target state. As a result, unlike Datagram TLS and Kerberos, SSP does not need to maintain a replay cache." Reordering and duplication are free. Every packet carries what state the sender believes the receiver is in, which is exactly the "client sends its latest known server state number" property.

**Roaming.** "Every time the server receives an authentic datagram from the client with a sequence number greater than any before, it sets the packet's source IP address and UDP port number as its new target." The client never learns it roamed; there is no reconnect handshake at all.

**Timing (paper + source).** Min frame interval = ½ SRTT (≈1 Instruction in flight), frame rate capped at **50 Hz**; **collection interval 8 ms** after the first application write (originally guessed 15 ms, tuned to the minimum of the measured curve); **delayed ACK 100 ms** (sufficient to piggyback in >99.9 % of cases); **heartbeat every 3 s** (roaming detection, NAT keepalive, staleness warning); **RTO floor 50 ms** vs TCP's 1 s. Source constants: `SEND_INTERVAL_MIN 20 ms`, `SEND_INTERVAL_MAX 250 ms`, `ACK_INTERVAL 3000 ms`, `ACK_DELAY 100 ms`, `SHUTDOWN_RETRIES 16`, `ACTIVE_RETRY_TIMEOUT 10000 ms` (`src/network/transportsender.h`); `MIN_RTO 50`, `MAX_RTO 1000`, `SERVER_ASSOCIATION_TIMEOUT 40000 ms`, `PORT_HOP_INTERVAL 10000 ms`, `MAX_OLD_SOCKET_AGE 60000 ms`, `DEFAULT_SEND_MTU 500 B`, `DEFAULT_IPV4_MTU 1280 B`, ports 60001–60999, `MAX_PORTS_OPEN 10`, protocol version 2 (`src/network/network.h`). Instructions larger than the MTU are fragmented with `(id, fragment_num, final)` (`transportfragment.h`).

**Predictive echo.** Predictions are grouped into **epochs**: "either all of the predictions in an epoch will be correct, or none will." An epoch begins *tentative* — predicted but not displayed. As soon as one prediction in the epoch is confirmed by the server, the rest and all future predictions in that epoch are displayed immediately. Keys that are likely to change the echo regime (up/down arrows, control characters) increment the epoch, dropping back to background prediction. This handles vi modes and `passwd`-style echo suppression without app changes.

The decisive trick is **server-side confirmation**: client-only checking and client-side timeouts both produced flicker (apps take tens of ms to echo; jitter delays the real echo past any client timeout). Final design: a **server-side 50 ms timeout** and an **"echo ack" field inside the synchronized terminal object** naming the latest keystroke that has been in front of the application for ≥50 ms. "The client has no timeouts of its own, and consequently network jitter does not adversely affect the client's ability to evaluate whether a prediction is correct." Cost: an extra datagram ~50 ms after a keystroke.

Display thresholds (`src/frontend/terminaloverlay.h`): `SRTT_TRIGGER_LOW 20 ms` / `HIGH 30 ms` (adaptive on/off), `FLAG_TRIGGER_LOW 50 ms` / `HIGH 80 ms` (underline unconfirmed text), `GLITCH_THRESHOLD 250 ms`, `GLITCH_REPAIR_COUNT 10`, `GLITCH_REPAIR_MININTERVAL 150 ms`, `GLITCH_FLAG_THRESHOLD 5000 ms`. Validity states: `Pending`, `Correct`, `CorrectNoCredit`, `IncorrectOrExpired`, `Inactive`; display preference `Always | Never | Adaptive | Experimental`.

**Results.** 6 users, 40 h, 9,986 keystrokes. **70 %** of keystrokes displayed instantly. Sprint EV-DO: median **5 ms** (mean 173 ms) vs SSH median **503 ms** (mean 515 ms). Verizon LTE with a concurrent TCP download: SSH median 5.36 s vs Mosh <0.005 s (mean 1.70 s). MIT→Singapore EC2: SSH 273 ms vs Mosh <5 ms (mean 86 ms). **0.9 %** of keystrokes showed a wrong prediction, repaired within an RTT, mostly from word wrap. At 50 % round-trip loss with predictions off: SSH median 0.416 s / mean 16.8 s vs Mosh 0.222 s / 0.329 s.

**No scrollback, by construction.** SSP conveys "the most recent state" and deliberately skips intermediate states, so a `cat` of a large file has no accurate history. The paper's answer is `less`, `screen` or `tmux`. Other limits: UDP only, SSH bootstrap for key exchange, unprivileged server, no port forwarding/X11.

**Over TCP/WebSocket/QUIC?** The state-diff and idempotence ideas port cleanly — an Instruction is self-contained `(source_state, target_state, diff)` and does not need ordered delivery, only the newest one matters. What does *not* port is the free roaming: it is a property of the datagram layer's "highest sequence number wins, rebind the address" rule. Over a stream you must replace it with an explicit session id + resume handshake (what Eternal Terminal does), and you re-acquire head-of-line blocking, which removes SSP's ability to skip intermediate frames under loss. Reuse was discussed on [mosh-devel](https://mailman.mit.edu/pipermail/mosh-devel/2012-August/000295.html). **Implementations:** upstream is C++ only. GitHub repo and code search (`gh api search/...`) surfaced **no JS/TS/WASM port of SSP or of the prediction engine**. The only substantial non-C++ consumer is [blinksh/blink](https://github.com/blinksh/blink) (Swift, ~6.9k stars, "Blink Mobile Shell for iOS (Mosh based)") which wraps the upstream C++ mosh rather than reimplementing SSP.

## 2. Eternal Terminal

Sources: [protocol.md](https://github.com/MisterTea/EternalTerminal/blob/master/docs/protocol.md), [howitworks](https://eternalterminal.dev/howitworks/), `src/base/BackedWriter.hpp`.

Pure **byte/packet-stream replay over TCP**, no screen model. `BackedReader` counts bytes received (its sequence number); `BackedWriter` "keeps an encrypted buffer of the last N bytes sent and the sequence number" and on reconnect resends the difference. Both ends run both. Reconnect flow: client re-sends `ConnectRequest` with the same 16-char client-id → server answers `RETURNING_CLIENT` → bidirectional **`SequenceHeader`** exchange of last-received sequence numbers → **`CatchupBuffer`** swap of the missing *encrypted* packets. Bootstrap is SSH: `echo 'XXX<16-char client-id>/<32-char passkey>_xterm-256color' | etterminal`, then a direct connection to `etserver` on **port 2022**. Constants in `BackedWriter.hpp`: `MAX_BACKUP_BYTES` = **64 MB** ("maximum bytes to buffer for recovery"), `DISCONNECT_BUFFER_BYTES` = **64 MB** (max buffered while disconnected before blocking); sequence numbers are `int64_t`; `recover(int64_t lastValidSequenceNumber)` returns the serialized packets the peer still needs. Limits: no predictive echo, TCP head-of-line blocking, no X forwarding ("ET does not implement the full SSH protocol"), needs a persistent `etserver` daemon.

## 3. tmux / screen and web-terminal products

**tmux.** `history-limit` default is **2000 lines per pane** (`options-table.c:844-850`, `.default_num = 2000`). The server owns the pty and the screen; a client attaching gets a repaint from server-held state, not a byte replay. Control mode (`-C`, `-CC` = no echo) emits `%output`, `%begin`/`%end`, `%subscription-changed` etc. ([tmux(1)](https://man.openbsd.org/tmux)); iTerm2 drives it to build native windows and its docs state windows reopen "in the same state they were in before" but publish **no figure for scrollback restored on attach**.

**ttyd.** [README](https://github.com/tsl0922/ttyd): `--ping-interval` default **5 s**, `--max-clients`, `--once`, `--exit-no-conn`. **No reconnect and no replay buffer** are documented — a dropped WebSocket loses the view.

**VS Code.** [docs/terminal/advanced](https://code.visualstudio.com/docs/terminal/advanced): two modes — *process reconnection* (window reload: reconnect to the live process and restore its content) and *process revive* (restart: content restored, process **relaunched**). `terminal.integrated.enablePersistentSessions` defaults **true**; `terminal.integrated.persistentSessionScrollback` default **100 lines** (vs `terminal.integrated.scrollback` default **1000**); `terminal.integrated.persistentSessionReviveProcess` configures revive separately. Server side, `src/vs/platform/terminal/common/terminalRecorder.ts` keeps a per-terminal recording capped at `MaxRecorderDataSize = 10 * 1024 * 1024` (**10 MB**), trimming oldest chunks, and `generateReplayEvent()` emits `{ events: [{ cols, rows, data }] }` — i.e. **byte replay with dimension changes interleaved**, written back through xterm.js.

**Coder.** `agent/reconnectingpty/buffered.go`: a `circbuf.NewBuffer(64 << 10)` — a **64 KiB** ring buffer (`github.com/armon/circbuf`); PTY output is read in 1024-byte chunks, written to the ring and fanned out live; on attach the whole buffer is cloned and written to the new connection before it joins the live feed. Sessions are keyed by a **UUID** supplied by the client, `attachTimeout` 30 s, default idle timeout 5 min. Byte replay from a fixed-size tail, no offsets.

**xterm.js `@xterm/addon-serialize`.** `serialize(options?)` returns a **string of escape sequences that reconstructs the framebuffer and repositions the cursor**; options `range`, `scrollback` (rows from the bottom of scrollback), `excludeModes`, `excludeAltBuffer`. Docs advise writing it *before* `Terminal.open` and into a terminal of the same size.

## 4. Which approach each product uses

| Product | Approach |
|---|---|
| Mosh | (b) screen-state sync, diffs between numbered states; no scrollback |
| Eternal Terminal | (a) byte replay, 64 MB buffer, byte sequence numbers |
| tmux / screen | (b) server-held screen; 2000-line pane history |
| VS Code | (a)+(c): 10 MB byte recorder, 100 lines replayed; revive restores content and relaunches the process |
| Coder | (a) 64 KiB ring replay keyed by session UUID |
| Warp | Local only. [Session restoration](https://docs.warp.dev/terminal/sessions/session-restoration) restores windows/tabs/panes and recent Blocks from a local SQLite DB, on by default; **no documented remote/SSH session resume** |
| Zed remote | Remote daemon survives; "proxy mode" reconnect starts or reattaches to the daemon; unsaved changes persisted locally. **No documented message replay or sequence numbers** ([docs](https://zed.dev/docs/remote-development)) |
| Ghostty | `window-save-state` (macOS, layout only); "scrollback currently exists completely in memory" — **no session persistence** |
| Blink (iOS) | Mosh (SSP), i.e. (b) |
| Termius | Not documented in any source I could fetch (support site returns 403) — **unverified** |

## 5. Input safety and pending-input display

- **Mosh**: input is itself a synchronized object, so an Instruction's diff carries *every intervening keystroke*, applied idempotently by state number. Exactly-once falls out of the state numbering; there is no per-keystroke ack protocol.
- **Eternal Terminal**: symmetric byte sequence numbers + `CatchupBuffer`; exactly-once because both sides know the peer's last received byte offset.
- **Discord Gateway** ([docs](https://docs.discord.com/developers/events/gateway)): `RESUME` carries `session_id` + last received `seq`; the gateway "sends the missed events in order, finishing with a `Resumed` event". Reconnect goes to `resume_gateway_url`. First heartbeat is delayed by `heartbeat_interval * jitter`, jitter ∈ [0,1). A **zombied** connection is one where no heartbeat ACK arrives before the next heartbeat is due → close with any code other than 1000/1001 and reconnect. Non-resumable: `Invalid Session` with `d: false`, and codes 4002 (payload >4096 bytes), 4013, 4014.
- **Centrifugo** ([history and recovery](https://centrifugal.dev/docs/server/history_and_recovery)): stream position = **`epoch` + `offset`**; `epoch` changes when history is lost so the client knows to resync rather than silently miss data; `recovered: true` means the gap was fully covered; `client.recovery_max_publication_limit` default **300** publications per reconnect — "recovery handles short disconnects, not hour-long absences".
- **Figma** ([multiplayer blog](https://www.figma.com/blog/how-figmas-multiplayer-technology-works/)): local edits applied optimistically; server is last-writer-wins per property; the client **discards incoming server values that conflict with its own unacknowledged edits** ("our change is our best prediction because it's the most recent change we know about in last-to-the-server order") — this is the anti-flicker rule. On reconnect it downloads a fresh document copy and reapplies offline edits.
- **Displaying unconfirmed input**: Mosh underlines unconfirmed predictions only on high-delay links (`FLAG_TRIGGER_LOW 50 ms` / `HIGH 80 ms`, plus `GLITCH_FLAG_THRESHOLD 5000 ms` for very old ones); "this underline trails behind the user's cursor and disappears gradually as responses arrive".

## 6. iOS specifics

- **Background/suspension.** `beginBackgroundTask(expirationHandler:)` grants a *finite*, unpublished amount of time (`backgroundTimeRemaining` reports it); Apple's docs stress calling it "as early as possible before starting your task, preferably before your app actually enters the background" — calling it at the end of `applicationDidEnterBackground(_:)` may lose the race with suspension. The expiration handler runs synchronously on the main thread; failing to call `endBackgroundTask(_:)` kills the app. `BGAppRefreshTask` requires the `fetch` background mode and carries no timing guarantee.
- **`URLSessionWebSocketTask`** has **no auto-reconnect**. `sendPing(pongReceiveHandler:)`'s handler receives an error "that indicates a lost connection or other problem", and pongs are delivered in ping order — usable as an RTT/liveness probe with an app-side deadline. `maximumMessageSize` is "the maximum number of bytes to buffer before the receive call fails". `waitsForConnectivity` is explicitly **establishment-only**: "If a connection is established and then drops, the completion handler or delegate receives an error."
- **Better path.** Apple's documented pattern for `NWConnection.betterPathUpdateHandler` is make-before-break at the app layer: "If you can migrate your work to a new connection, try establishing a new connection. Once that new connection is ready, cancel the original connection." `viabilityUpdateHandler` signals when data can actually flow. There is no transport-level migration for TCP/WebSocket.
- **Radio cost.** Apple's Energy Efficiency Guide states radios "are powered down by default… then they remain up for the duration of the activity and for an additional period of time in anticipation of more work", and that "sporadic network transactions result in high overhead"; cellular costs significantly more than Wi-Fi. Apple publishes **no tail-time figure** — I could not find an authoritative seconds number in Apple's docs, so any sub-5 s ping cadence has to be justified by measurement, not citation.

## 7. QUIC / HTTP3

[RFC 9000](https://www.rfc-editor.org/rfc/rfc9000.html#section-9): §9 connection migration **does preserve the connection and its streams across a client IP/port change** — "connection migration uses connection identifiers to allow connections to transfer to a new network path", and §5.1 makes connection IDs the identity so "changes in addressing at lower protocol layers (UDP, IP) do not cause packets… to be delivered to the wrong endpoint". Constraints: migration is **client-initiated only** (a server may only advertise `preferred_address`, §9.6); **zero-length connection IDs disable migration** (§5.1.8, §9.5); a new path must pass PATH_CHALLENGE/PATH_RESPONSE validation (§8.2) and is subject to the anti-amplification limit; congestion controller and RTT estimates are **reset** on the new path (§9.4). Idle timeout is the negotiated `max_idle_timeout` (min of both peers, §10.1) with PING to defer it (§19.2) — **RFC 9000 specifies no default value**.

0-RTT (RFC 9001) resumes only the *cryptographic* context from a TLS ticket; it creates a **new connection with new stream state**, and is subject to anti-replay restrictions. It does not restore an application session. WebTransport over HTTP/3 is at **draft-ietf-webtrans-http3-16 (2026-07-06), in WG last call**; it discusses 0-RTT only as retaining SETTINGS/flow-control values and defines **no session-resumption mechanism**. Apple exposes `NWProtocolQUIC` in Network.framework but does not expose migration control as app-level API.

Net: QUIC migration covers an IP change on a still-live connection within the idle timeout. It does **not** cover app suspension past the idle timeout, process death, server restart, or a fully closed connection — all of which still need an application-level resume token + offset.

## Design ingredients (mechanisms, with who uses each)

1. **Session id + resume handshake over a stream** — client-id → `RETURNING_CLIENT` (ET), `session_id`+`seq`→`RESUME` (Discord), session UUID (Coder), reconnection token (VS Code pty host).
2. **Bidirectional sequence numbers exchanged at resume, then replay the gap** — ET `SequenceHeader`/`CatchupBuffer` (64 MB each way), Discord ordered replay ending in `Resumed`, Centrifugo `offset`.
3. **Epoch/generation token that invalidates an offset** — Centrifugo `epoch`: the client learns the stream was rebuilt instead of silently missing data.
4. **Bounded tail buffer sized by bytes** — Coder 64 KiB ring, VS Code 10 MB recorder trimmed oldest-first, ET 64 MB.
5. **Screen-state snapshot instead of history** — Mosh terminal object; xterm.js `@xterm/addon-serialize` (escape-sequence string + cursor, `scrollback` option); tmux server-held screen.
6. **Hybrid snapshot-then-tail** — VS Code replay events `{cols, rows, data}` re-establish geometry before content; serialize addon advises restoring into a same-size terminal, then resizing.
7. **State-diff Instructions `(source, target, diff)` that are idempotent and skippable** — Mosh SSP; removes replay caches and lets the sender drop intermediate frames.
8. **Input as a synchronized object, not a byte pipe** — Mosh client→server object whose diff is every intervening keystroke: exactly-once without per-key acks.
9. **Server-authoritative echo-ack with a fixed server-side hold (50 ms)** — Mosh; the client keeps no timeout, so jitter cannot cause prediction flicker.
10. **Epoch-gated prediction display** — Mosh: predict in the background, reveal the whole epoch on the first confirmation, re-tentative on hard keys (arrows, control chars).
11. **Confidence-gated decoration of unconfirmed input** — Mosh underline between `FLAG_TRIGGER_LOW 50 ms` and `HIGH 80 ms` SRTT, `GLITCH_THRESHOLD 250 ms`, trailing and fading.
12. **Local prediction wins over stale server state** — Figma: discard incoming server values conflicting with unacked local edits.
13. **Rate control decoupled from output volume** — Mosh: min frame interval ½ SRTT, 50 Hz cap, 8 ms collection interval, 100 ms delayed ack; keeps Ctrl-C responsive under flood.
14. **Application heartbeat with jitter and an ack deadline** — Mosh 3 s heartbeat; Discord `heartbeat_interval * random(0,1)` first beat and "no ACK ⇒ zombie ⇒ close with code ≠1000/1001"; ttyd `--ping-interval 5 s`; `URLSessionWebSocketTask.sendPing` for the client side.
15. **Address rebinding on highest-sequence-number packet** — Mosh datagram layer (UDP only); the stream-transport equivalent is #1+#2.
16. **Make-before-break on a better path** — Apple `betterPathUpdateHandler`: open the new connection, wait for ready, then cancel the old (which composes with #1 to avoid a visible gap).
17. **QUIC connection migration** (RFC 9000 §9) for IP changes on a live connection — non-zero-length CIDs, path validation, congestion reset — with an application resume still required for suspension/idle-timeout/server-restart.
18. **Process-outlives-connection daemon** — tmux/screen, ET `etterminal`, Coder agent, VS Code pty host, Zed remote daemon.