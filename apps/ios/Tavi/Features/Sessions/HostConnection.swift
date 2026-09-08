import Foundation
import Observation

// How the phone is doing against one paired computer right now (#50).
// Reported per host so one computer being asleep never hides another.
enum HostHealth: Equatable {
    // No snapshot yet since the stream started.
    case connecting
    // The events stream is up; what is shown is what the host says.
    case live
    // The stream dropped but the host answers: reconnecting, showing the
    // last known state.
    case stale
    // The host itself does not answer (asleep, off the tailnet, or this
    // phone is offline). Last known state stays on screen.
    case offline
    // The host rejected this phone's credential; only pairing again helps.
    case revoked
}

// What the stream tells the directory it feeds. Everything else the link
// knows about itself it publishes; these are the two things only the
// directory can act on.
enum HostConnectionEvent {
    case snapshot(agents: [AgentSummary], available: Bool, reason: String?)
    case revoked(reason: String)
}

// The events stream for one paired computer (#50): the socket, the
// reconnect schedule, and the reachability probe behind the home's
// connection header. What the host says about agents goes to the
// directory; what the link is doing is this type's own truth. The dial
// itself and the deadlines that cut it are in HostConnectionDeadlines.
@MainActor
@Observable
final class HostConnection {
    private static let eventsProtocol = "tavi.events.v1"
    // Retry cadence for the events stream. A computer that is asleep or off
    // the tailnet is dialled again at 2, 4, 8, then every 10 s — not every
    // 2 s for hours (owner-felt, 2026-09-02: robin-PC unplugged). The
    // connect deadline bounds "Connecting…": a peer that has said nothing
    // after 5 s is probed, and no answer means Offline — the phone never
    // waits out a silent handshake to admit it.
    private static let eventsReconnect = ReconnectPolicy(
        initialDelay: .seconds(2),
        // Ten, not thirty: a person is looking at this screen, and a link
        // that comes back should be caught within seconds (#86).
        maximumDelay: .seconds(10),
        multiplier: 2,
        connectDeadline: .seconds(5)
    )
    private static let latencyInterval: Duration = .seconds(30)

    private(set) var isRunning = false
    // True after the first snapshot ever arrives; before that an empty list
    // means "still loading", not "no agents".
    private(set) var hasLoaded = false
    // The stream is down and the directory's agents are the last known
    // state (PRD §7.8: resume with an explicit stale indicator, never a
    // blank screen). A blocked agent therefore stays visible through
    // reconnects until a live snapshot actually reports it resolved.
    private(set) var isStale = false
    // The host rejected this phone's credential outright (#46): revoked on
    // the Mac, or the host was reset. Retrying cannot fix it; only pairing
    // again can, so the stream stops and the home says so.
    private(set) var isRevoked = false
    // The host did not answer the last reachability probe (#50). Set only
    // after a stream drop whose follow-up probe timed out or failed at the
    // connection level; cleared by the next live snapshot.
    private(set) var isOffline = false
    // Round trip to an authenticated endpoint, refreshed while the stream
    // is up and on every drop probe. nil until measured.
    private(set) var latencyMilliseconds: Int?
    // How this phone reaches the computer, per the computer's own Tailscale
    // (`GET /api/host` → `connection`); `.unknown` from an older host.
    private(set) var path: ConnectionPath = .unknown

    private var host: HostEndpoint?
    private var credential = ""
    private let transport: HostClient.Transport
    let makeSocket: @Sendable (URLRequest) -> any HostEventsSocketing
    let watchdogPolicy: HostWatchdogPolicy
    let reconnectPolicy: ReconnectPolicy
    let timing: ConnectionTiming
    // The retry delay this link is sitting out, so a signal that the network
    // is back can end it early instead of waiting the schedule out (#111).
    private let retryWait: RetryWait
    // "Does this computer answer at all?" — the same question the deadline,
    // the drop path and the latency poll all ask (#101, #111).
    let reachability: HostReachability
    private var onEvent: ((HostConnectionEvent) -> Void)?
    // Where this link's recoveries are recorded (#111); nil records nothing.
    var recovery: RecoveryLog?
    var reconnectAttempt = 0
    private var streamTask: Task<Void, Never>?
    // The live events socket. `stop()` must close it itself: cancelling the
    // task alone leaves `receive()` waiting for the host's next frame, and a
    // quiet host never sends one — the connection, its socket and its
    // buffers then live on (measured 2026-09-02: 242 directories after 200
    // home → terminal → home trips, ~140 KB and one host stream each).
    // Network.framework, not URLSession: see NetworkWebSocketTask (#70).
    var socket: (any HostEventsSocketing)?
    private var latencyTask: Task<Void, Never>?
    // Unstructured on purpose, since the redial must never wait for a probe;
    // the link owns each by name and `stop()` ends them all (#108).
    var connectDeadlineTask: Task<Void, Never>?
    private var firstFrameLatencyTask: Task<Void, Never>?
    private var reachabilityTask: Task<Void, Never>?
    var consecutiveFailedDials = 0
    var streamConnectedAt: ContinuousClock.Instant?
    // Two fences (#108). A measurement (round trip, path) belongs to the dial
    // that took it. A verdict about the computer (Offline, revoked) belongs
    // to the generation, which only stopping, reconfiguring or a snapshot
    // moves, so failed redials cannot starve it.
    var epoch = 0
    var reachabilityGeneration = 0
    // The dial a deadline cycled, so its cause is not overwritten by the
    // cancelled socket the catch then sees (#111).
    var cycledDial: Int?
    // The watchdog's one outstanding challenge to a quiet socket (#107).
    var watchdogPing: Task<Void, Never>?
    var watchdogPingGeneration = 0
    // The handover check, in its own slot so a stalled watchdog send can
    // never suppress it (#111): the challenge, the send it owns until that
    // send returns or the socket is cancelled, and the deadline judging both.
    var handover: HandoverChallenge?
    var handoverSend: Task<Void, Never>?
    var handoverDeadline: Task<Void, Never>?
    // What no socket reports: the phone's own network moving.
    private let pathWatch: NetworkPathWatch

    // Tests hand in their own transport, socket and schedule so no unit test
    // opens a real socket or waits out a real redial (#99).
    init(
        transport: @escaping HostClient.Transport = { try await HostSession.shared.data(for: $0) },
        makeSocket: @escaping @Sendable (URLRequest) -> any HostEventsSocketing = { NetworkWebSocketTask(request: $0) },
        watchdogPolicy: HostWatchdogPolicy = .live,
        reconnectPolicy: ReconnectPolicy? = nil,
        timing: ConnectionTiming = .live,
        pathObserver: any NetworkPathObserving = NetworkPathObserver()
    ) {
        self.transport = transport
        self.makeSocket = makeSocket
        self.watchdogPolicy = watchdogPolicy
        self.reconnectPolicy = reconnectPolicy ?? Self.eventsReconnect
        self.timing = timing
        retryWait = RetryWait(timing: timing)
        pathWatch = NetworkPathWatch(observer: pathObserver)
        reachability = HostReachability(timing: timing)
        reachability.install(
            client: { [weak self] in self?.client },
            epoch: { [weak self] in self?.epoch ?? 0 },
            generation: { [weak self] in self?.reachabilityGeneration ?? 0 },
            onPath: { [weak self] answered in
                guard let self, answered != path else { return }
                path = answered
            },
            onAnswer: { [weak self] probe, origin in
                self?.recovery?.record(.probe(probe), source: .events, generation: origin)
            }
        )
    }

    // Everything this link asks the host over HTTP goes through one client,
    // so the bearer and the query live in HostClient alone (#96).
    private var client: HostClient? {
        guard let host, !credential.isEmpty else { return nil }
        return HostClient(endpoint: host, credential: credential, transport: transport)
    }

    // The repos poll runs beside this stream only while the stream is
    // usable: a revoked, offline or reconnecting link would add a half-open
    // socket to the redial's own (#72).
    var isPollable: Bool { !isRevoked && !isOffline && !isStale }

    var health: HostHealth {
        if isRevoked { return .revoked }
        if isOffline { return .offline }
        if !hasLoaded { return .connecting }
        return isStale ? .stale : .live
    }

    func configure(
        host: HostEndpoint?,
        credential: String,
        recovery: RecoveryLog? = nil,
        onEvent: @escaping (HostConnectionEvent) -> Void
    ) {
        stop()
        self.host = host
        self.credential = credential
        self.recovery = recovery
        self.onEvent = onEvent
        hasLoaded = false
        isStale = false
        isRevoked = false
        setOffline(false, dial: epoch)
        latencyMilliseconds = nil
        // The previous computer's path is not this one's.
        path = .unknown
        streamConnectedAt = nil
        guard host != nil, !credential.isEmpty else {
            // Nothing can connect without a credential or a valid address,
            // and "Connecting…" forever would be a fabricated state. Say so
            // with the same offers as a revocation: pair again or remove.
            isRevoked = true
            hasLoaded = true
            return
        }
        start()
    }

    func start() {
        // A dead credential stays dead: re-dialing it on every foreground
        // would only produce 401s (#46).
        guard streamTask == nil, !isRevoked, let host, let client else { return }
        guard let eventsURL = try? host.eventsURL() else { return }
        // A handshake that gets no answer must fail on its own clock, not
        // the system's minute-long default: the connect deadline decides
        // what the home says, this decides when the attempt is abandoned.
        // Eight seconds: a handshake through a relay takes about one; a
        // radio that is still waking up must fail fast so the redial runs.
        var handshake = client.request(eventsURL, timeout: 8)
        handshake.setValue(Self.eventsProtocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        isRunning = true
        // The watch outlives any one dial (#111).
        pathWatch.start { [weak self] event in self?.pathChanged(event) }
        // A foreground is a fresh start (#86, owner 2026-09-03 01:10: "the
        // reconnection took a while" after the phone had been idle): the
        // dials that count are the ones from now, so the backoff and the
        // failed-dial count begin at zero, and the first redial after a
        // wake-up failure is 2 s away, not 30.
        reconnectAttempt = 0
        consecutiveFailedDials = 0
        // Offline stays Offline until a snapshot proves otherwise. Resetting
        // it here showed "Connecting…" on every foreground for as long as
        // the handshake took to time out — for an unplugged computer, every
        // time the owner looked (2026-09-02).
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.streamOnce(handshake: handshake)
                guard !Task.isCancelled else { return }
                // The dial that just ended: a wake meant for it is honoured
                // here, and one meant for an earlier dial is discarded.
                let dial = self.epoch
                self.reconnectAttempt += 1
                await self.retryWait.sleep(
                    self.reconnectPolicy.delay(forAttempt: self.reconnectAttempt),
                    dial: dial
                )
            }
        }
        latencyTask = Task { [weak self, timing] in
            while !Task.isCancelled {
                try? await timing.sleep(Self.latencyInterval)
                guard !Task.isCancelled, let self else { return }
                guard self.hasLoaded, !self.isStale else { continue }
                let asked = self.epoch
                // A link that moved on mid-probe loses this one number, not
                // the poll (#108).
                if case let .reachable(latency) = await self.reachability.ask(), asked == self.epoch {
                    self.latencyMilliseconds = latency
                }
            }
        }
    }

    // Ends the delay the link is sitting out, so a network that came back
    // dials now; the path watch is what calls it (#111).
    func wakeRetry() {
        retryWait.wake(dial: epoch)
    }

    func stop() {
        // Invalidate before cancelling: a cancelled task still resumes and
        // runs its `defer`s (#108).
        epoch += 1
        reachabilityGeneration += 1
        streamTask?.cancel()
        streamTask = nil
        retryWait.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        cancelWatchdogPing()
        cancelHandover()
        pathWatch.stop()
        latencyTask?.cancel()
        latencyTask = nil
        reachability.cancel()
        connectDeadlineTask?.cancel()
        connectDeadlineTask = nil
        firstFrameLatencyTask?.cancel()
        firstFrameLatencyTask = nil
        reachabilityTask?.cancel()
        reachabilityTask = nil
        isRunning = false
        // Whatever we show next launch/foreground is last-known until the
        // stream confirms otherwise.
        if hasLoaded { isStale = true }
    }

    // What one text frame does to the link, and whether it was the agents
    // snapshot this dial was waiting for (`measured`). Out of line because
    // `streamOnce` is at its complexity bound; here rather than beside the
    // dial because it is the only part of one that writes what the home reads.
    func apply(_ text: String, dial: Int, attempt: Int, measured: inout Bool, dialledAt: ContinuousClock.Instant) throws {
        let snapshot = try JSONDecoder().decode(AgentsSnapshotMessage.self, from: Data(text.utf8))
        guard snapshot.type == "agents" else { return }
        // The frame the dial's whole budget was for: the 5 s probe arm and
        // the 15 s first-frame arm are both done here, and nowhere else —
        // control frames and other text do not buy a dial more time (#111).
        cancelConnectDeadline(dial)
        recordSnapshot(afterDrop: isStale || isOffline, dial: dial, attempt: attempt)
        hasLoaded = true
        isStale = false
        setOffline(false, dial: dial)
        isRevoked = false
        // A frame is the answer any verification was waiting for (#108).
        reachabilityGeneration += 1
        reachabilityTask?.cancel()
        reachabilityTask = nil
        onEvent?(.snapshot(agents: snapshot.agents, available: snapshot.available, reason: snapshot.reason))
        if streamConnectedAt == nil { streamConnectedAt = timing.now() }
        guard !measured else { return }
        measured = true
        recordFirstFrame(dial: dial, attempt: attempt, since: dialledAt)
        measureFirstFrameLatency(dial)
    }

    // The last known agents stay on screen, explicitly stale — dropping them
    // made "Needs you" blink away on every network blip while the agent was
    // still waiting. Said by a dial that ended and by a path that is gone.
    func markStale() {
        isStale = true
    }

    // Offline is a verdict about the computer: earned and cleared once each,
    // so the log's two counts stay paired (#111). The guard is the one
    // non-observational effect P1 has on this type: a redundant `isOffline =
    // false` no longer wakes every view observing it.
    func setOffline(_ value: Bool, dial: Int) {
        // With no path of its own the phone knows nothing about the
        // computer, so no new Offline is earned while it is unsatisfied
        // (#111). One already earned is not masked, and a 401 still revokes.
        if value, pathWatch.current?.isSatisfied == false { return }
        guard isOffline != value else { return }
        isOffline = value
        recovery?.record(value ? .offlineEntered : .offlineCleared, source: .events, generation: dial)
    }

    // The first snapshot proves the stream; the round trip is measured
    // right behind it.
    private func measureFirstFrameLatency(_ dial: Int) {
        firstFrameLatencyTask?.cancel()
        firstFrameLatencyTask = Task { [weak self] in
            guard let self, case let .reachable(latency) = await self.reachability.ask() else { return }
            guard dial == self.epoch else { return }
            self.latencyMilliseconds = latency
        }
    }

    // A WebSocket drop and an HTTP 401 look alike, so ask the host directly
    // before deciding; the same probe says whether the computer answers at
    // all (#50). It runs beside the redial, never in front of it: waiting the
    // double probe out first made the app miss every short good window on a
    // WiFi link that goes deaf for seconds (2026-09-02). One verification per
    // generation, not per dial: on a black-holing computer each question
    // waits out its 5 s timeout while redials arrive every 8–10 s, so a
    // restart per dial meant the pair never finished (#108).
    func verifyReachability(_ dial: Int) {
        guard reachabilityTask == nil else { return }
        let generation = reachabilityGeneration
        reachabilityTask = Task { [weak self] in
            guard let self else { return }
            let probe = await self.reachability.askTwice(generation)
            defer { if generation == self.reachabilityGeneration { self.reachabilityTask = nil } }
            guard generation == self.reachabilityGeneration else { return }
            switch probe {
            case .rejected:
                self.isRevoked = true
                self.setOffline(false, dial: dial)
                self.hasLoaded = true
                self.isStale = false
                self.recovery?.record(.revoked, source: .events, generation: dial)
                self.onEvent?(.revoked(reason: "This iPhone is no longer paired with this computer. Pair it again to reconnect."))
                self.stop()
            case let .reachable(latency):
                self.setOffline(false, dial: dial)
                if dial == self.epoch { self.latencyMilliseconds = latency }
            case .unreachable:
                if self.isStale, self.consecutiveFailedDials >= 2 { self.setOffline(true, dial: dial) }
            // Never really asked; the next drop verifies.
            case .superseded: break
            }
        }
    }
}
