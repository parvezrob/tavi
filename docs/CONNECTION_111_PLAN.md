# #111 — Connection 10/10: the locked plan (2026-09-06)

> **Status: LOCKED 2026-09-06 (owner's call after four review rounds).** Canonical copy is also the comment on
> [issue #111](https://github.com/parvezrob/tavi/issues/111). This file exists so an implementer in a worktree
> can read it without network access. When P0–P4 have landed, the durable decisions live in `docs/PRD.md` §7.13,
> `protocol/README.md` and `docs/DEVELOPMENT.md`, and this file is deleted (its final state rotates to
> `docs/history/`). Review record: two GPT-6 Astra seats per round through `.claude/skills/second-opinion`
> (round 1 fresh + domain; round 2 fold-audit + fresh; round 3 fold-audit + fresh; round 4 two fold-audits →
> one LOCKABLE, one with four concrete leftovers folded into v5; a narrow fifth seat then confirmed the four
> leftovers against the code — it read v4 by a scripting slip and marked them MISSED; v5 below is the version
> that folds them, checked line by line against that seat's list; no further round per the owner's lock).

# #111 plan — Connection 10/10 (v5 after rounds 1–4 of cold GPT-6 seats, 2026-09-06)

Issue: https://github.com/parvezrob/tavi/issues/111 (body pasted at the end). Base: `main` at `9976289`.
Governs: `AGENTS.md` (sub-agent loop; fault-injection rule; never overlay shared docs; verification ladder;
the Mac is the host), `docs/PRD.md` §7.13, `docs/DEVELOPMENT.md`, `protocol/README.md`.

v2 → v3 (round 2: fold-audit + fresh eyes, both NOT LOCKABLE): faults are now **runner-driven** (a fault
fires only after the phone's own counters show 30 s healthy, so backoff-reset assumptions are observed,
not presumed; `slowReady` is armed atomically with the terminate that precedes it); byte integrity is
**offset contiguity + a host checkpoint**, not resume hits; MARK exactly-once only in fault-free windows,
at-most-once always, with the reader's cumulative count as the independent tally; false Offline is a
correlated transition, not a probe flag; handover pong **correlated by payload**; the handover challenge
has its own slot and one 2 s deadline covering send + pong, and shortens an outstanding ordinary round;
events backoff gains the terminal's time-based reset (a stream that held 30 s resets attempts when it
ends) — authorised as a P2 change; `.lost` marks stale and keeps retrying, only the Offline verdict is
withheld; `.restored` cycles a retained socket and wakes the sleeping retry; `claim` stays immediate under
`slowReady` (only `ready` + output are held); revocation closes bypass the chaos gate; one monotonic time
domain; the diagnostics element is visible to XCUI; the refusal boundary names `isEphemeral` too; budgets
recomputed; P5 adds a physical Wi-Fi→cellular handover with log evidence.

v3 → v4 (round 3: fold-audit + fresh eyes, both NOT LOCKABLE, three HIGH-class items left): the soak
fixture gets a **control command** (`STOP` stops the stream and prints an authoritative per-MARK tally;
the reader never sees `kill`); a resumed `ready` is **checked against the requested resume point**
(`resumeMismatch` counter; the accepted offset is never silently replaced); an **absolute first-frame
deadline** per events dial (15 s) so a peer that pings but never sends a snapshot cannot hold Connecting;
the time-based events reset requires **liveness over the interval** (`lastActivity − connectedAt ≥ 30 s`),
not merely time; path loss **never masks an earned Offline**, it only withholds new verdicts; a
diagnostic-only path stamp exists from P1; recovery durations come from **exported event timestamps**,
not the sampler; production retention stays **bounded** (ring 50 + scalar counters + one current-stream
offset), the complete history lives in the test collector; the matched handover pong is **latched** per
challenge; the wake credit is consumed or discarded at the next dial; the shortened heartbeat deadline is
absolute across send→pong; blackhole budget allows a round mid-send (30 s); host heartbeat tests inject
send completion; unused repeating chaos profiles cut; P5's release-time expectation removed.

v4 → v5 (round 4: two fold-audit seats; one LOCKABLE, one with four concrete leftovers, confirmed by a
narrow fifth seat that read v4): MARK syntax is validated exactly and a lone `⏎` precedes every healthy MARK
so a partial fragment lands as `JUNK`, never glued to the next marker; the tally is read from the fixture's
file on the Mac, not the screen; a phone probe disagreement (unreachable while the runner is reachable and the
path satisfied) **fails** the false-Offline assertion instead of being excluded, and a window without path
evidence is an incomplete measurement; the liveness reset counts **delivered frames only** (a receive error
stamps `lastActivity` before throwing today, so a new `lastFrameAt` is the input); `hostPause` **withholds
responses** (connections hang, upgrades are never answered) instead of answering 503, which the probe
classifies as reachable; the terminal blackhole window is 30 s so no round's deadline can land after the
unpause; the handover challenge keeps its send and deadline owned until completion or socket cancellation.

## What is true today (verified against the code; corrections from rounds 1–2 folded)

- **Terminal** (`TerminalSessionController.swift`, 594 lines): 12 s ready deadline over a 10 s TCP budget;
  retries 250 ms → 8 s (jitter 80–100 %), reset only after 30 s connected (`readyAt`); `TerminalHeartbeat`
  every 10 s, 5 s send bound + 5 s pong bound; a satisfied→satisfied path change calls `heartbeat.start(…,
  immediately: true)`, which **stops and restarts** the heartbeat (a second path event cancels an
  outstanding challenge); `NWPathMonitor` per controller; an **initial unsatisfied** snapshot triggers
  recovery before the baseline guard. `.outputChunk` handling accepts any chunk the bridge queues and sets
  the resume offset to `offset + count` — **a gap or overlap in offsets is not detected**; `.ready` replaces
  the resume point with whatever the host answered, so a `resumed: true` at an offset other than the one
  requested passes unnoticed. Reasons: closed
  enum `TerminalRecoveryReason` → `Logger("terminal.connection")` only. `TerminalOutbound` reports an
  abandoned send as `.failed(…, inputWasSubmitted:)`; not every abandoned keystroke produces a record.
- **Terminal UI** (`TerminalSessionView.swift`): a healthy terminal shows **no** `terminal.status`; final
  states speak from the bottom bar with a sentence ("Another connection took over. Open this terminal
  again to reconnect."), also under `terminal.status`. "Live" in the existing tests = `terminal.keyboard`
  present ∧ `terminal.status` absent. The surface's accessibility value is the active grid only, capped at
  8 192 scalars, published asynchronously (≈ 250 ms); herdr sends screen diffs — screen text proves
  freshness, never byte delivery.
- **Events link** (`HostConnection.swift`, 564 lines): redial 2 → 10 s (attempt 1 = 1.6–2 s), 5 s connect
  deadline → probe; Offline after two frameless dials + two missed probes; watchdog polls every 5 s
  (effective 30–35 s ping / 45–50 s cycle); the ping is owned and carries an **empty payload**; `Date()` /
  `Task.sleep` directly (no injected clock); the retry sleeps in `Task.sleep` with no wake hook; **backoff
  resets only when a snapshot arrives after 30 s up** — a quiet stream never resets, so after a long quiet
  evening every redial is at the 10 s cap. **No path observer.** Decoder requires `type`, `available`,
  `agents`; another `type` with those fields is skipped, a frame without them → `decode-failed` → cycle
  (same at `29327dc`). Offline is set from unreachable probe results in `verifyReachability` and the connect
  deadline; `health` gives `isRevoked` then `isOffline` precedence over stale; revocation (401) is definitive
  and independent of the path. **Nothing bounds a dial that receives control frames but never a snapshot**:
  the 5 s deadline only probes, and the watchdog reads any frame as activity — today a real host always
  sends a snapshot on connect, so it has not mattered; with server pings (P2) it would.
- **Events tests**: `WatchdogSocket` fabricates `lastActivity` from `Date()` at every read; `cancel` only
  counts; `receive()` is never released.
- **Host**: no server heartbeat; `ws` 8.21.3 has `autoPong`, `pause()`/`resume()` (pauses the socket; frames
  already in the receiver still deliver; teardown drains buffered data into the receiver), `terminate()`;
  `keepAuthorized` clears its timer then `close(4401)`; attachment ring 1 MiB, retention 120 s **from host
  release**, detach grace 8 s **from host release** → desktop resize. `bridgeTerminalV2` claims first
  (`onOutput: flush`) then sends `ready`, then flushes; `onSuperseded` fires from `claim` (re-claim) and from
  `AttachmentStore.create` → `supersede` (fresh replacement), both through the attachment's current client.
  `herdr-events.ts` publishes only changed snapshots. `index.ts` reads `TAVI_AUTO_UPDATE` from `process.env`;
  the launchd env is a fixed list (`service.ts`); `isManagedRuntime` = the `~/.tavi/runtime` install,
  `isEphemeral` (`package-root.ts`) = an `_npx` run. The preview door binds `TAVI_PREVIEW_PORT` (8788).
- **Transport** (`NetworkWebSocketTask.swift`): `autoReplyPing = true`; the iOS 26 SDK header
  (`ws_options.h` › `nw_ws_options_set_auto_reply_ping`) says pings are still delivered to receive requests;
  `lastActivity` (a `Date`) is stamped in the receive completion **before** the error check, so a receive
  error or close also advances it; pong payloads are dropped. `TerminalTiming.now` is a `ContinuousClock.Instant`.
- **Live tests**: `TAVI_DEV_HOST` must be `https://….ts.net[:port]` (port kept); helpers are `private` in
  `TaviUITests.swift`; `TaviMemoryChecks` has a private `LiveEnvironment`; background/foreground restarts
  every events link (`SessionsView` scene handling).
- **Machine**: launchd runs the checkout's `apps/host/dist` (0.1.17 build); Serve maps `:443 → 8787`,
  `:8443 → 8788`; the simulator is a serial resource; soaks only with the owner off the phone.

## Packages — one worktree, one PR, one Astra code review each, merged in order

### P0 — Behaviour-preserving prerequisites (phone only; small, reviewed alone)

1. **`NetworkPathWatch`** (`Features/Terminal/Transport/`, ~70 lines, `@MainActor`): owns the monitor
   task, dedups equal snapshots, reports `.lost`, `.restored`, `.changed(from, to)` to one closure. Exact
   current semantics: an **initial unsatisfied** snapshot is `.lost`; an initial satisfied snapshot is
   baseline only; `stop()` cancels. The controller drops its monitoring code and keeps "what each event does
   to a connection". Tests: `NetworkPathWatchTests` (initial-unsatisfied, initial-satisfied, repeated equal,
   changed, stop); `TerminalRecoveryTests` unchanged through `ScriptedPathObserver`.
2. **One time domain + injected timing in `HostConnection`**: `TerminalTiming` → **`ConnectionTiming`**
   (sleep + monotonic `now: ContinuousClock.Instant`), injected into `HostConnection` for every sleep and
   every age/deadline; `HostEventsSocketing.lastActivity` and `NetworkWebSocketTask`'s stamp become
   `ContinuousClock.Instant` (both consumers are ours); wall-clock `Date` survives only in what a person
   reads (the log's timestamp). The retry sleep becomes a **wakeable wait** owned by the stream task:
   generation-scoped, completes exactly once (timer or wake, whichever first), released by cancellation,
   a wake arriving before registration is remembered as one credit that the **next dial consumes or
   discards** (it never carries into a later outage). Tests: wake/timeout/stop/reconfigure orderings, and
   wake-after-timeout-before-dial. No behaviour change yet.
3. **Honest `WatchdogSocket`**: `lastActivity` / `lastPong(payload)` advance only by scripted arrivals;
   `cancel` releases a pending `receive()` with `.cancelled`; a scripted `receive()` can hand a snapshot
   to the replacement dial. Existing watchdog tests re-expressed.
4. **Shared live helpers** `TaviUITests/LiveHostHelpers.swift`: `LiveEnvironment`,
   `createDisposableShell`, `createAgentTab`/`closeAgentTab`, `launchIntoAgent`, `waitForLiveTerminal`,
   `waitForTranscript` moved out of `TaviUITests.swift`.

Gate: `check.sh` green, recovery suites unchanged in count and intent, no new public API beyond these.

### P1 — Chaos host + soak harness + recovery counters (numbers first)

**Host** — `apps/host/src/chaos.ts` (≤ 300 lines) + `routes/chaos.ts` + hooks in `websocket-upgrades.ts`,
`terminal-bridge.ts`, `herdr-events.ts` (retained snapshot only):
- `TAVI_CHAOS=on` read in `index.ts` (one mode; faults come from the runner — no repeating profiles until a
  manual test needs one). Refused (exit 2, one sentence) when
  `NODE_ENV=production`, `isManagedRuntime(...)` or `isEphemeral(...)`. Stated boundary: the launchd
  service cannot carry it (fixed env), a managed or `_npx` install cannot run it; a developer's checkout or
  `npm i -g` can. Startup line `CHAOS <mode>: this host injects faults`; each fault one `log.warn("chaos", …)`.
  `on` injects nothing by itself.
- **Routes (chaos only; 404 otherwise; authenticated like every `/api` route):**
  - `POST /api/chaos/fault` `{ kind: "terminate" | "blackhole" | "closeMidOutput", socket: "events" |
    "terminal", paneId?, ms?, code?, thenSlowReadyMs? }` → `201 { id, at }`. `thenSlowReadyMs` arms the
    delay for the **next attach on that pane atomically before** the terminate fires, and the response of
    `GET /api/chaos/events` later names the dial that consumed it.
  - `GET /api/chaos/events` → every fault fired `{ id, at, kind, socket, paneId?, consumedByAttachAt? }`.
  - `GET /api/chaos/attachments` → per pane `{ stream, startOffset, endOffset, claims, resumeHits,
    resumeMisses, supersedes, lastReadyOffset, releasedAt?, resizedAt? }` (the last two are the host-side
    times P5 needs).
- **Fault mechanics:**
  - `terminate` — `websocket.terminate()`: no close frame (the wire cannot carry 1006). The phone's tag is
    recorded, not asserted.
  - `blackhole(ms)` — `websocket.pause()` **and a write gate** for that socket: snapshot send, terminal
    `flush`, `pong`, `error`, P2's server ping, and ordinary close frames all check the gate. **Revocation
    bypasses it**: in chaos mode `keepAuthorized` first drops application handling (the bridge's ownership
    flag and the events subscription, synchronously, so a receiver drain at teardown reaches nothing) and
    then `terminate()`s, so `close(4401)` can never be held.
    Events: the latest skipped snapshot is retained and sent when the window ends. Terminal: `flush` is
    held; the cursor waits; `resume()` flushes. Tests: frames already in the receiver at `pause()` still
    deliver (documented `ws` behaviour, asserted not assumed); a paused socket that closes or is superseded
    discards its retained snapshot and never resumes application traffic; receiver-drain ordering delivers
    once, in order.
  - `slowReady(ms)` (only via `thenSlowReadyMs`) — the bridge **claims immediately** (so `onSuperseded`
    stays reachable and ownership is never ambiguous) and holds `ready` **and** `flush` together for the
    delay; supersession or close during the hold cancels it and the superseded frame goes out as today.
    Events: the first snapshot is held; a newer snapshot arriving meanwhile replaces it.
  - `closeMidOutput(code)` — orderly `close(1011 | 1001, reason)` while output is flowing.
  - **Takeover is the harness's**: a second real `tavi.v2` client from the test process.
- Tests: refusal matrix; `terminate` sends no close frame; `blackhole` keeps TCP open, answers no ping in
  the window, answers after, gates every write, re-sends the retained snapshot, never gates `4401`;
  `slowReady` sends nothing before `ready`, keeps the claim, is cancelled by close and by supersession;
  a fault never touches an unscheduled socket; the routes 404 without chaos.

**Phone** — recovery counters and the soak:
- **`RecoveryLog` model** (`Features/Sessions/RecoveryLog.swift`, ~90 lines, `@MainActor @Observable`):
  ring of 50 `RecoveryEvent { at: Date, monotonic: ContinuousClock.Instant, source: Source, kind: Kind,
  reason: Reason, generation: Int, attempt: Int, elapsedMilliseconds: Int, resumed: Bool?, pathSatisfied:
  Bool? }` where `Source` (`terminal` | `events`), `Kind` (`cycling`, `ready`, `takenOver`, `streamEnded`,
  `snapshotAfterDrop`, `offlineEntered`, `offlineCleared`, `revoked`, `outputDiscarded`, `offsetGap`,
  `offsetOverlap`, `handoverChecked`, `handoverFailed`) and `Reason` (`terminal(TerminalRecoveryReason)` |
  `socket(SocketFailure.Tag, code: Int)` | `none`) are **closed enums** — no `String` field exists.
  Beside the ring, **bounded scalar counters per source**: `dials`, `readies`, `resumeHits`,
  `resumeMisses`, `resumeMismatches`, `cycles[reason]` (one Int per closed-enum case), `offsetGaps`,
  `offsetOverlaps`, and for the **current stream only** `acceptedOffset` (replaced on a fresh attach). No
  per-stream dictionaries, no transition lists: production retention is the ring plus scalars; the complete
  history is the **test collector's** (the soak reads the diagnostics element every 2 s and merges ring
  events by their monotonic timestamp — fewer than 50 events ever occur in 2 s). `pathSatisfied` is stamped
  on every record from a **diagnostic-only** `NetworkPathWatch` the log owns from P1 (no behaviour hangs on
  it until P2). One log per paired computer, owned by `AgentDirectory`; `HostConnection` records through a
  closure installed at `configure`; the terminal controller takes a recorder in `connect(...)`. Existing
  `Logger` lines and the log write from one `record(_:)`. Causes are recorded **before** the socket is
  cancelled. Kinds added: `probe(reachable | unreachable | rejected)`, `firstFrameDeadline`.
- **Offset contiguity** (a product check, tiny): in `.outputChunk`, if `offset != resumePoint.offset`
  the controller records `offsetGap` (offset ahead) or `offsetOverlap` (offset behind) before accepting; on
  `.ready(resumed: true)` the answered `(stream, offset)` is compared with the **requested** resume point and
  a difference records `resumeMismatch` (a `resumed: false` answer legitimately restarts the accepted offset
  and counts a `resumeMiss`). Nothing else changes in P1; a non-zero gap/overlap/mismatch in the soak is a
  host defect to fix, not a tolerance.
- **DEBUG diagnostics element**: under `TAVI_DEV_HOST` launches only, a real (not hidden) 1-pt clear
  `Text` in the accessibility tree, identifier `diagnostics.recovery.<hostId>`, value = the counters as one
  JSON line. The soak **reads and decodes it before arming anything** (smoke).
- **`TaviChaosSoak.swift`** (gated `TEST_RUNNER_TAVI_CHAOS=1`, `…_CHAOS_MINUTES` default 20, live env
  pointing at the chaos host, `TAVI_CHAOS=on`). **Runner-driven**: a fault is requested only when the
  phone's counters show the relevant socket **live for ≥ 30 s** (so the backoff is observed reset — the
  terminal resets by time; the events link resets only when a snapshot arrives after 30 s up, so in P1 the
  home phase **records the attempt count** at each cycle and budgets from it). Two phases:
  - **Terminal phase** (first half): disposable shell; `launchIntoAgent`; fixture typed once (a short `sh` script pasted as one bracketed paste, `stty -echo` first):
    a background stream `( i=0; while :; do i=$((i+1)); echo "SOAK $i"; sleep 0.2; done ) &`, and a
    foreground reader that **counts per MARK** and understands one control word: `case "$line" in
    MARK-[0-9]*) [then the exact syntax `^MARK-[0-9]+$` is checked with `expr` — POSIX `case` patterns
    are globs, so the pattern alone is not the check] append "$line" to the tally file
    `/tmp/tavi-soak-<pane>.tally`; printf 'ACK %s\n' "$line";; STOP) kill the stream, wait, printf
    'END\n';; *) printf 'JUNK %s\n' "$line";; esac`. The runner types a lone `⏎` **before every healthy
    MARK**, so a fragment left by an abandoned send (`MARK-1` without its newline) is delimited and lands as
    `JUNK MARK-1`, never as `MARK-1MARK-2`. A typed `MARK-k⏎` is evidence of execution only as `ACK MARK-k`;
    the **tally file, read by the runner from the Mac's disk after `END`, is the authoritative per-MARK
    execution count** (runner and chaos host share the machine; the screen shows only `END`, so nothing
    scrolls away); screen sampling is for freshness only. Faults in rotation: `terminate`, `blackhole 30 s`,
    `terminate + slowReady 6 s`, `closeMidOutput 1011`, `closeMidOutput 1001`, then takeover once
    (isolated), then repeat. A `MARK` is typed (a) once per fault-free window ≥ 10 s after recovery and
    ≥ 10 s before the next fault, and (b) once deliberately 1 s before each fault. Sampler (best effort,
    timestamped): live = `terminal.status` absent ∧ `terminal.keyboard` present; recovering = the
    `terminal.status` label; final = the sentence; the surface value for `SOAK` freshness; the counters
    element every 2 s.
  - **Home phase** (second half): the terminal closed, the home open; faults on the events socket:
    `terminate`, `blackhole 70 s` (past the 45–50 s watchdog boundary, so the cycle is unambiguous),
    `closeMidOutput 1001`. Sample the computer's health label (`SessionsHomeHealth`; an identifier is added
    if it lacks one) and the counters element; the runner polls `/api/health` every 2 s as its own record of
    the host being up (evidence about the runner's path to the host, stated as such).
  - **Assertions and budgets** (every duration is computed from the **exported event timestamps** —
    `cycling` → `ready`, fault `at` → `cycling` — never from when the 2 s sampler happened to look; the
    sampler's own observations get a separate ±2 s allowance and serve the UI assertions only. Dial latency
    on the Mac's tailnet measured and reported, expected ≤ 4 s incl. herdr lookup; `A` = the attempt count
    read from the counters at the cycle):
    - `terminate` / `closeMidOutput` (terminal): live again ≤ **4.5 s** when `A == 1` (0.25 s + 4 s dial),
      generally ≤ `delay(A) + 12 s`; a dial that misses its 12 s deadline is a finding, not tolerance.
      `closeMidOutput` → `ready.resumed == true`.
    - `blackhole 30 s` (terminal; longer than the worst detection so no round's deadline can fall after the
      unpause and be satisfied by a late pong): the heartbeat detects ≤ 25 s after the start (a round may be
      awaiting its send completion for up to 5 s when the pause begins, then ≤ 10 s to the next beat + 5 s
      send bound + 5 s pong bound); live ≤ **30 s** after the start with `A == 1` (the redial is a fresh TCP
      connection the pause does not touch); detection and recovery reported separately.
    - `terminate + slowReady 6 s`: one cycle (the terminate's), **no additional deadline-induced cycle**;
      report `upgrade + lookup + 6 s` against the 12 s deadline.
    - **Input**: from the tally file — every `MARK-k` executed **at most once**; a `MARK` typed in a
      fault-free window executed **exactly once**; a `MARK` typed 1 s before a fault executed at most once
      and its outcome is reported (protocol/README.md permits an abandoned send; `JUNK` lines are reported
      as partial deliveries); after every recovery the next fault-free `MARK` is acked (forward progress).
    - **Integrity** (terminal phase): `offsetGaps == 0`, `offsetOverlaps == 0`, `outputDiscarded == 0`,
      `resumeMismatches == 0`, `resumeMisses == 0` **excluding** the initial attach and the explicit reopen
      after takeover (deliberate fresh attaches, counted separately); at the final checkpoint the runner
      types `STOP⏎`, waits for `END` on screen and 3 s more, then compares the phone's `acceptedOffset`
      with `attachments.endOffset` for the live stream (equal, and no host output after `END`). `SOAK` advances within 3 s of every sample after each recovery (freshness, async
      publication allowed).
    - **Home**: a **false Offline** = an `offlineEntered` event whose timestamp falls inside a window where
      the runner's `/api/health` polls (±5 s) all answered **and** the phone's path was satisfied; count
      must be 0. The phone's own `probe` events in that window are reported beside it: two unreachable phone
      probes while the runner was reachable on a satisfied path **is** a false Offline (that disagreement is
      the defect being hunted, so it fails), and a window with no path evidence is an **incomplete
      measurement**, reported as such, never as zero. The soak also runs one deliberate contrast: `blackhole`
      on the events socket **plus** `POST /api/chaos/fault {kind: "hostPause", ms}`, which makes the chaos
      host **withhold every response** for the window (HTTP requests hang until the client's timeout,
      upgrades are never answered; an answered status, even 503, is classified reachable by the phone) →
      Offline **is** expected after two frameless dials and two missed probes; the harness proves it can see
      both outcomes. `blackhole 70 s` → cycled by the watchdog ≤ 50 s idle (P1) / ≤ 40 s (P2), then
      `Reconnecting`, then live ≤ `delay(A) + 4 s` (P1 reports `A`; after P2's time-based reset `A == 1`
      → ≤ **6 s**). `terminate` (events) → live ≤ `delay(A) + 4 s`.
    - **Takeover** (terminal phase, isolated): the superseded sentence ≤ 5 s after the second client's
      `ready`; the second client keeps draining for 60 s; the **terminal** `dials` counter is unchanged
      for those 60 s and across one background/foreground (the events counters move; that is correct);
      then the soak reopens the terminal explicitly.
  - **Numbers** (an `XCTAttachment` JSON + a printed table): per fault kind the detection- and
    recovery-time distributions (min/median/max, n), attempts at each cycle, resume hits/misses (deliberate
    fresh attaches separated), offset gaps/overlaps, cycles by reason, false Offlines, MARK acks
    (once / never / twice, by window kind), dial-latency distribution. **Baseline = the first full run
    against the phone at the P1 head**, recorded on #111 before P2. Phone jitter (80–100 %) makes exact
    replay impossible; distributions are the comparison unit.
- **Owner-run recipe** (`docs/DEVELOPMENT.md` › iOS): build the P1 worktree's host; run
  `TAVI_PORT=8797 TAVI_PREVIEW_PORT=8798 TAVI_STATE_DIR=~/.tavi-chaos TAVI_CHAOS=on node dist/index.js`;
  publish `tailscale serve --bg --https=9443 http://127.0.0.1:8797` (remove: `tailscale serve --https=9443
  off`); export `TEST_RUNNER_TAVI_DEV_HOST=https://<mac>.ts.net:9443` and that host's token (`npm run -s
  token` with the same `TAVI_STATE_DIR`); signed simulator build (`CODE_SIGNING_ALLOWED=YES
  CODE_SIGN_IDENTITY=-`), compile first, then the soak alone. The real host and phone are untouched;
  herdr is shared, so the disposable shell shows on the real home for the run.

### P2 — Server heartbeat on the events socket + 2 s handover checks (measured against P1)

**Smoke first (≤ 5 min, simulator):** a chaos-host `ws.ping()` every 5 s → the phone's `.ping` frame lands
in `receiveMessage`, `lastActivity` moves, the host sees the auto pong — for the new phone against the new
host and against a 0.1.17 host (no pings; nothing changes). The SDK documents delivery; the smoke confirms
it over the real route. If it did not hold, P2 stops and the plan is re-reviewed.

**Host** — `socket-heartbeat.ts` `keepAlive(websocket, { intervalMs: 15_000 })`, wired for the **events**
socket only: `ping()` every 15 s; a `pong` (any payload) marks the socket answered; a ping sent while the
previous one is unanswered counts a miss; on the second miss (**45 s** without a pong) → `terminate()`.
Timer unref'd, cleared on close; pings go through the chaos gate and a gated socket is not counted.
`keepAlive` takes its timer and the ping's send-completion as injectable seams. Tests with a `ws` client
`autoPong: false` (miss at 30 s, terminate at 45 s from the last pong or from connect; a pong resets;
blackholed → not counted), injected-time slow pong (44 s answers), close mid-interval, a ping whose
send-completion never returns (the next tick still counts the miss and terminates on schedule), and close
while a send-completion is pending (no throw, timer cleared). Terminal sockets are
**out** for #111 (a server terminate 30–45 s into a 60 s tunnel would hand the pane to the desktop size at
38–53 s and start retention earlier, no measured benefit) — noted on #68 finding 8. `protocol/README.md`
gains "Events WebSocket (`tavi.events.v1`)": the frame, the 15 s ping / 45 s terminate, and the field
decoder's contract (a text frame must carry `type`, `available`, `agents`).

**Phone — events link**
- `HostWatchdogPolicy.live` → `pingAfterIdle 20`, `cycleAfterIdle 35` (effective 20–25 / 35–40 s with the
  5 s poll, documented). A 0.1.17 host answers the phone's ping with `ws`'s auto pong; no wire change.
- **Liveness-based backoff reset**: a stream resets `reconnectAttempt` **when it ends** if it showed
  liveness across the stable interval — `socket.lastFrameAt − streamConnectedAt ≥ 30 s` at the drop, where
  `lastFrameAt` (new on `HostEventsSocketing`, stamped by `NetworkWebSocketTask` **only for delivered
  frames**: text, binary, ping, pong — never for an error or close completion, which today advance
  `lastActivity` before throwing) is the input; the server's pings count, a socket that received one snapshot
  and then nothing until it failed does **not** qualify. Today only a snapshot arriving after 30 s resets it,
  so a quiet evening redials at the 10 s cap. Tests: repeated single-snapshot blackholes keep the attempt
  climbing; a snapshot at 0 s and a receive error at 31 s does not reset. PRD §7.13 wording updated.
- **First-frame deadline**: each dial has an absolute **15 s** budget to deliver its first agents snapshot;
  control frames do not extend it (`connectDeadlineTask` already fires at 5 s to probe — this is a second,
  later arm of the same task that cycles the socket with reason `first-frame-deadline` and records it).
  Test: a peer that answers the upgrade and pings every 5 s but never sends a snapshot is cycled at 15 s and
  redialled; a snapshot at 14 s cancels it.
- **Pings carry a payload**: `HostEventsSocketing.ping(payload: Data)`; `NetworkWebSocketTask` sends it
  and delivers `.pong` payloads through `onPong: (Data) -> Void` (set by the link; payload stays out of any
  log). The link **latches** `challengeAnswered = true` when a pong's payload equals the outstanding
  challenge's — a later unrelated pong cannot overwrite the evidence (test: matching pong then an unrelated
  pong before the deadline → satisfied). The challenge's send stays **owned** (its task and the deadline)
  until the send completes or the socket is cancelled; a pong arriving does not release a still-pending send.
- `NetworkPathWatch` injected (`Scripted` in tests). `.changed` with an **established dial** (≥ 1 frame
  received on this dial; a dial in progress keeps its budget untouched) → one **handover challenge** in its
  **own slot** (`handoverChallenge`, independent of `watchdogPing`, so a stalled watchdog send cannot
  suppress it): a ping with a fresh payload and **one 2 s deadline from the path change covering send and
  pong**; success = a pong with **that payload** on the same socket and epoch; on miss record
  `handoverFailed(handover-pong-missing | handover-send-stalled)` and cycle; on success record
  `handoverChecked`. **Coalesced**: further `.changed` events while a challenge is outstanding are ignored
  (earliest deadline wins). A late pong from an earlier watchdog ping does not satisfy it (payload
  mismatch). `stop()` cancels it like every task.
- `.restored` → if a socket is retained, cancel it (`goingAway`, cause recorded first); the wakeable wait
  fires so the redial runs now; attempt count and epoch kept (no `stop()/start()`). `.lost` → `isStale`
  when loaded (a Live home says Reconnecting, §7.13), the retry loop **keeps its schedule** (recovery never
  depends on a future path event), and **no new Offline verdict is earned while the path is unsatisfied**
  (`unreachable` probe results do not set `isOffline`); an **already-earned Offline is not masked** — it
  stays until a snapshot, as today (`health` precedence unchanged); `rejected` still revokes — definitive
  regardless of path. Tests from both starting states (Live → `.lost`; Offline → `.lost`).
- Tests (fault-injection rule, on the honest `WatchdogSocket` + `ConnectionTiming`): slow peer (pong at
  1.9 s passes, at 2.1 s cycles); ping whose send never returns (the 2 s deadline cycles once); server
  close delivered mid-challenge (exactly one redial; the replacement dial is not touched by the old
  deadline; the old send completing late is ignored); `.changed` during a dial in progress (no cancel,
  budget intact); path flapping every 1.5 s during a challenge (one challenge, original deadline); an old
  watchdog pong arriving after the challenge started (payload mismatch → still cycles at 2 s); a server
  ping advancing `lastActivity` does not satisfy a challenge; `.restored` wakes the sleeping retry without
  resetting the attempt and cycles a retained socket; `.lost` + two unreachable probes → not Offline;
  Offline then `.lost` → still Offline; `.lost` + 401 → revoked; a stream with frames spanning 30 s that drops
  resets the attempt, one spanning 29 s does not, one with a snapshot at 0 s and silence until a cycle at
  40 s does not, one with a snapshot at 0 s and a receive error at 31 s does not; first-frame deadline with
  pings only.
**Phone — terminal**
- `HeartbeatPolicy.handover = 2 s` — one deadline from the path change covering send + pong for the
  challenge round. `start(generation:, immediately: true)` **does not restart** an outstanding round: if a
  round is outstanding its deadline becomes an **absolute** `min(existing, change + 2 s)` that survives the
  round's send → pong transition (today the pong bound is created fresh when the send completes; the
  shortened absolute deadline is carried into it) — never lengthened; only the absence of a round starts a
  new one. `handoverChecked` / `handoverFailed` recorded.
- Tests: handover with a suspended send (2 s cycle); server close mid-challenge with the replacement
  reaching `ready` and then the old pong/deadline completing (one retry, resume offset unchanged,
  replacement heartbeat intact); flapping during a challenge (one round, shortened deadline kept); an
  ordinary round outstanding at 4 s of its 5 s budget when the path changes → cycles at 5 s not 6 s; a round
  whose send completes 0.1 s before the shortened deadline keeps that deadline for its pong (no fresh 5 s);
  slow peer at 1.9 / 2.1 s.
- Re-run the P1 soak; after numbers on #111 beside the baseline (distributions; home-phase `A == 1`).

### P3 — Connection log UI (model and counters exist since P1)

`ManageAccessView` gains a "Connection log" row → `ConnectionLogView`: newest first, one monospaced
line per event (`21:14:03  terminal  cycling  heartbeat-pong-missing  gen 4  try 2  5001 ms  path ok`),
a Copy button (`UIPasteboard`, the same lines), empty state "No recoveries since Tavi opened".
Identifiers `connectionLog.copy`, `connectionLog.row.<n>`. The soak attaches the copy text at the end
of each phase. Tests: `RecoveryLogTests` (ring cap 50, order, counters past the ring); the line format.
PRD §7.13: what the log is and what it never holds.

### P4 — #101 carve-outs that remain coherent (no line target)

`HostConnection`: the probe machinery (`probeInFlight`, `probeHost*`, `HostProbe`, `HostAnswer`) →
`HostReachability`, behaviour identical, `HostConnectionProbeTests` unchanged. `TerminalSessionController`:
grid synchronisation (`lastSentGrid`, `reconcileGridIfNeeded`, the resize sends) → `TerminalGridSync`;
the outbound outcome handling stays (it owns input errors, metrics and recovery together). Acceptance:
"each moved piece has one reason to change and the existing suites pass unchanged". Baseline re-recorded
with relative paths.

### P5 — Physical phone (owner-run, not in the loop; the log open afterwards)

Install `main` over USB. Record, per experiment, the phone log and `/api/chaos/attachments` from a chaos
host (`releasedAt`, `resizedAt`, offsets): (a) airplane 30 s, low output → `ready.resumed == true`, no
repaint, and whether the host released/resized at all; (b) airplane 60 s → record **when** the host observed the release (`releasedAt`, a dead path delivers no
close, so this is the host's own detection) and whether it resized (`resizedAt`): is the repaint acceptable,
or should the grace scale with the blackout budget; (c) a burst above the ring (≥ 1 MiB during the blackout) → fresh attach by design; (d)
> 120 s since release → fresh attach by design; (e) **Wi-Fi → cellular handover with both up**
(satisfied→satisfied): the log must show `handoverChecked` (or `handoverFailed` + one cycle) for both
the terminal and the events link — the production observer identifies the path by its first interface,
and this is the only place that path fires. Only after those numbers is `DETACHED_RETENTION_MS`,
`DETACH_GRACE_MS` or the ring tuned, if at all. Then the §7.13 release check (Wi-Fi off, cellular, twenty
minutes); the log's copy goes on #111 as the close-out evidence.

## Loop per package

Opus 5 implements in an isolated worktree with a strict brief (scope, acceptance, "no new abstractions
beyond the ones named here, comments only for why") → two cold Opus verifiers (correctness/scope;
quality/restraint) → fix round → orchestrator gates in the ladder order: **compile first** (host
`npm run build`; phone `xcodebuild build`), then targeted `-only-testing:`, then the full gate (host
`check`/`lint`/`test`/`check:lengths`; phone `apps/ios/scripts/check.sh`); the soak only with the owner
off the phone → **GPT-6 Astra code review via `second-opinion`** (fresh-eyes + code-health lens on the
diff, verdict before the PR opens) → PR → fast-forward merge. Shared docs merged with `git merge-file`.

## Docs touched

`protocol/README.md` (P2: events section, heartbeat, decoder contract; changelog), `docs/PRD.md` §7.13
(P2 marks, handover, time-based events reset; P3 the log), `docs/DEVELOPMENT.md` (P1 chaos + soak recipe;
P0/P4 code map; P3 log), `current-session.md` + `handoffs.md` per session; #68 gets the terminal-heartbeat
note.

## Implementation notes carried (MEDIUM/LOW from the seats, not plan changes)

The host heartbeat's "45 s" is from the last pong or from connect; after an arbitrary pong the terminate
lands 30–45 s later depending on interval alignment — the protocol text says "two unanswered pings", not a
fixed number. The 8 s events handshake timeout bounds TCP, not snapshot readiness (the 15 s first-frame
deadline does). Terminal resources after the soak return to baseline (the memory-check counts apply).

`ws.pause()` leaves already-received frames deliverable and teardown drains the receiver — tested, not
assumed. `slowReady` after a `terminate` legitimately passes through Reconnecting once. Counter deltas are
asserted per source and per phase, deliberate attach boundaries excluded. The soak's ±5 s health window
and 3 s freshness window are tolerances for asynchronous publication, not budgets. P5's timers start at
host release, so host times are recorded beside phone times.

## Risks kept

1. `blackhole` models an established socket that goes silent with TCP up; not packet loss, not a vanished
   interface, not a stalled tiny send — those are P5's.
2. The simulator soak measures the app's reaction on a good link; §7.13's release check remains the proof.
3. Phone jitter makes exact replay impossible; distributions are compared, not timestamps.
4. The chaos host on `:9443` needs one `tailscale serve` command and its own state dir from the owner.

## Issue #111 body (verbatim)

Follow-up to #107 and #108 (merged 2026-09-06 via #109 and #110). Those fixed how the app recovers from
a drop. This issue is what is left between "recovers" and "you never think about it", plus the way to
prove it without waiting for real drops.

Measure first (the #68 rule): every item below lands with a number before and after, from the harness in item 1.

1. Host chaos mode for soaks. `TAVI_CHAOS=<profile>` on the host (dev only, refused when
   `NODE_ENV=production`): drop the events socket every N s, delay `ready` by M s, black-hole pings for a
   window, close a terminal with 1006 mid-output, send `superseded` to a random client. A simulator UI soak
   (`TEST_RUNNER_TAVI_CHAOS=1`, 20 min) asserts the terminal is never on Connecting longer than the
   documented budget, no keystroke is replayed, the home never says Offline while the host answers.
   Numbers: longest Connecting, redials, bytes lost, false Offlines.
2. Host-initiated heartbeat on the events socket (#68 finding 8). Server pings every 15 s; the phone
   cycles on two misses. Today only the phone's watchdog notices a half-open socket, at 30–45 s idle.
3. Faster check on interface handover. A satisfied→satisfied path change now re-checks a live terminal
   with the normal 5 s pong budget. Use a 2 s budget for that first check only, and do the same for the
   events link (today it does nothing on a path change).
4. On-phone recovery diagnostics. The `terminal.connection` and `agents.directory` reason codes exist
   only in the unified log, so reading them needs a cable and Console.app. Keep the last 50 recovery
   events in memory (reason, generation, attempt, elapsed; nothing else) and show them under Settings →
   computer → "Connection log", with a copy button. That is how the owner tells the next session what
   happened on the train.
5. Terminal resume on a dead path. When the phone loses the pane to itself (old socket half-open, redial
   resumes), the host now supersedes the old socket and the phone ignores it. Confirm on the physical
   phone with airplane mode 30 s → back: same agent, no repaint, no replay. If it repaints, tune the
   host's attachment retention (120 s) against the phone's blackout budget.
6. #101 trim on the two big files (`HostConnection` 564, `TerminalSessionController` 594): path
   monitoring and the outbound outcome handling are the two coherent pieces left to carve out as owned
   types, the way `TerminalHeartbeat` was.

Not in scope: Tailscale relay vs direct (the phone shows it; the network decides it), the initiating radio
drop (never captured; the release check on the installed build is the proof).

Acceptance: the chaos soak passes on the simulator; the PRD §7.13 release check passes on the phone (Wi-Fi
off, cellular only, twenty minutes, no stall over a few seconds, no Offline while the Mac is up); the
connection log names every recovery that happened during it.
