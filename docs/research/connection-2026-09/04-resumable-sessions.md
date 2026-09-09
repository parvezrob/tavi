# Resumable remote-terminal protocols: facts (research agent, 2026-09-09)

## 1. Mosh / SSP
- Two SSP instances: client→server object = history of user input; server→client object = terminal window contents. Datagram layer (seq numbers, AES-OCB, SRTT, tracks client's public IP) + transport layer sending Instructions (source state, target state, diff). Idempotent, no replay cache; newest wins.
- Roaming: server rebinds target to the source of any authentic datagram with a higher seq. No reconnect handshake.
- Timing: min frame interval ½ SRTT, 50 Hz cap, 8 ms collection interval, 100 ms delayed ack, 3 s heartbeat, RTO floor 50 ms. Constants: SEND_INTERVAL_MIN 20 ms / MAX 250 ms, ACK_INTERVAL 3000, SERVER_ASSOCIATION_TIMEOUT 40 s, MTU 500 B.
- Predictive echo: epochs (all-or-nothing), tentative until first confirmation, server-side 50 ms echo-ack inside the synced terminal object; client has no timeouts. Display thresholds SRTT 20/30 ms (on/off), underline 50/80 ms, glitch 250 ms.
- Results (paper): 70 % of keystrokes instant; EV-DO median 5 ms vs SSH 503 ms; 0.9 % wrong predictions.
- No scrollback by construction; UDP only; SSH bootstrap. No JS/TS/Swift port of SSP exists; Blink wraps upstream C++.
- Over a stream: state-diff/idempotence ports; free roaming does not (needs session id + resume handshake); HOL blocking returns.

## 2. Eternal Terminal
- Byte replay over TCP: BackedWriter keeps last N bytes with seq numbers; reconnect = ConnectRequest(client-id) → RETURNING_CLIENT → SequenceHeader exchange → CatchupBuffer. MAX_BACKUP_BYTES 64 MB. Port 2022, SSH bootstrap. No predictive echo.

## 3. tmux / web terminals
- tmux history-limit default 2000 lines/pane; attach = repaint from server-held screen; control mode -CC.
- ttyd: ping-interval 5 s; no reconnect/replay.
- VS Code: persistent sessions on by default; persistentSessionScrollback 100 lines; server recorder 10 MB cap; replay events {cols, rows, data}; process reconnection vs revive.
- Coder: 64 KiB ring per reconnecting pty, session UUID, attachTimeout 30 s.
- xterm.js @xterm/addon-serialize: framebuffer → escape string + cursor; restore into same-size terminal.

## 4. Who uses what
Mosh: screen-state sync. ET: byte replay 64 MB. tmux: server-held screen. VS Code: byte recorder + replay. Coder: 64 KiB ring. Warp: local-only restore. Zed: daemon reattach, no replay. Ghostty: none. Blink: Mosh. Termius: unverified.

## 5. Input safety
- Mosh: input is a synced object; exactly-once from state numbering.
- ET: symmetric byte seq numbers.
- Discord Gateway: RESUME(session_id, seq) → missed events in order → Resumed; zombie = no heartbeat ACK → close ≠1000/1001 → reconnect.
- Centrifugo: position = epoch + offset; epoch change ⇒ resync; recovery limit 300 publications.
- Figma: local unacked edits win over conflicting server values (anti-flicker).

## 6. iOS
- beginBackgroundTask: finite, undocumented time; call before backgrounding.
- URLSessionWebSocketTask: no auto-reconnect; sendPing usable as liveness with app-side deadline; waitsForConnectivity is establishment-only.
- NWConnection betterPathUpdateHandler: make-before-break (open new, wait ready, cancel old). viabilityUpdateHandler = data can flow.
- Apple publishes no radio tail-time figure; ping cadence must be measured.

## 7. QUIC
- RFC 9000 §9: migration preserves connection + streams across client IP change; client-initiated; non-zero CIDs; path validation; congestion reset. Idle timeout negotiated, no default.
- 0-RTT resumes crypto only, new stream state. WebTransport draft-16 in WGLC, no session resume. Apple NWProtocolQUIC does not expose migration control.
- Net: migration covers IP change on live connection within idle timeout; app-level resume token + offset still needed for suspension, process death, server restart.

## Design ingredients
1 session id + resume handshake; 2 bidirectional seq numbers + gap replay; 3 epoch token invalidating offsets; 4 bounded byte tail buffer; 5 screen snapshot instead of history; 6 hybrid snapshot-then-tail with geometry first; 7 idempotent skippable state-diff instructions; 8 input as synced object; 9 server-authoritative echo-ack with 50 ms hold; 10 epoch-gated prediction display; 11 confidence-gated underline; 12 local prediction wins over stale server state; 13 rate control decoupled from output volume; 14 app heartbeat with jitter + ack deadline; 15 address rebinding on highest seq (UDP only); 16 make-before-break on better path; 17 QUIC migration for live IP changes; 18 process-outlives-connection daemon.
