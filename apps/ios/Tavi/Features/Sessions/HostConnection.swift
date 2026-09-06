import Foundation
import Observation
import os

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

// How often the events watchdog looks at its socket, and the two idle
// marks it acts on (#86, #107). A test shortens `pollInterval` so a run
// takes milliseconds; it crosses the idle marks through the socket's own
// `lastActivity` rather than by changing them.
struct HostWatchdogPolicy: Sendable, Equatable {
    let pollInterval: Duration
    let pingAfterIdle: TimeInterval
    let cycleAfterIdle: TimeInterval

    static let live = HostWatchdogPolicy(
        pollInterval: .seconds(5),
        pingAfterIdle: 30,
        cycleAfterIdle: 45
    )
}

// The events stream for one paired computer (#50): the socket, the
// reconnect schedule, and the reachability probe behind the home's
// connection header. What the host says about agents goes to the
// directory; what the link is doing is this type's own truth.
@MainActor
@Observable
final class HostConnection {
    private static let logger = Logger(subsystem: "com.farfield.tavi", category: "agents.directory")
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
    private static let supersededProbeAttempts = 3
    private static let stableStreamInterval: TimeInterval = 30

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
    private let makeSocket: @Sendable (URLRequest) -> any HostEventsSocketing
    private let watchdogPolicy: HostWatchdogPolicy
    private let reconnectPolicy: ReconnectPolicy
    private var onEvent: ((HostConnectionEvent) -> Void)?
    private var reconnectAttempt = 0
    private var streamTask: Task<Void, Never>?
    // The live events socket. `stop()` must close it itself: cancelling the
    // task alone leaves `receive()` waiting for the host's next frame, and a
    // quiet host never sends one — the connection, its socket and its
    // buffers then live on (measured 2026-09-02: 242 directories after 200
    // home → terminal → home trips, ~140 KB and one host stream each).
    // Network.framework, not URLSession: see NetworkWebSocketTask (#70).
    private var socket: (any HostEventsSocketing)?
    private var latencyTask: Task<Void, Never>?
    // Reconnect coordination (#86, PRD §7.13): one probe in flight however
    // many askers; Offline only after two dials in a row produced no frame;
    // the backoff resets only once the stream has been up for a while.
    private var probeInFlight: (origin: Int, task: Task<HostProbe, Never>)?
    // Unstructured on purpose — the redial must never wait for a probe — so
    // the link owns each by name and `stop()` ends them all (#108).
    private var connectDeadlineTask: Task<Void, Never>?
    private var firstFrameLatencyTask: Task<Void, Never>?
    private var reachabilityTask: Task<Void, Never>?
    private var consecutiveFailedDials = 0
    private var streamConnectedAt: Date?
    // Two fences, deliberately different (#108). A *measurement* belongs to
    // the dial that took it, so a superseded dial's round trip and path are
    // dropped rather than shown as the current one's. A *verdict about the
    // computer* belongs to the generation, which only stopping, reconfiguring
    // or a snapshot moves — failed redials, the case it exists to decide,
    // must not starve it.
    private var epoch = 0
    private var reachabilityGeneration = 0
    // The watchdog's outstanding challenge to a quiet socket, owned here so
    // there is never more than one and so teardown is deterministic (#107).
    private var watchdogPing: Task<Void, Never>?
    private var watchdogPingGeneration = 0

    // Tests hand in their own transport and socket so no unit test opens a
    // real one — the seam the terminal transport already has (#99) — and
    // their own schedule, so a redial or a connect deadline they need to
    // happen takes milliseconds instead of seconds.
    init(
        transport: @escaping HostClient.Transport = { try await HostSession.shared.data(for: $0) },
        makeSocket: @escaping @Sendable (URLRequest) -> any HostEventsSocketing = { NetworkWebSocketTask(request: $0) },
        watchdogPolicy: HostWatchdogPolicy = .live,
        reconnectPolicy: ReconnectPolicy? = nil
    ) {
        self.transport = transport
        self.makeSocket = makeSocket
        self.watchdogPolicy = watchdogPolicy
        self.reconnectPolicy = reconnectPolicy ?? Self.eventsReconnect
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

    func configure(host: HostEndpoint?, credential: String, onEvent: @escaping (HostConnectionEvent) -> Void) {
        stop()
        self.host = host
        self.credential = credential
        self.onEvent = onEvent
        hasLoaded = false
        isStale = false
        isRevoked = false
        isOffline = false
        latencyMilliseconds = nil
        // The previous computer's account of how the packets reached it is
        // not this one's, and the header would show it as current fact.
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
                self.reconnectAttempt += 1
                try? await Task.sleep(for: self.reconnectPolicy.delay(forAttempt: self.reconnectAttempt))
            }
        }
        latencyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.latencyInterval)
                guard !Task.isCancelled, let self else { return }
                guard self.hasLoaded, !self.isStale else { continue }
                let asked = self.epoch
                // Skipping, never returning: a link that moved on mid-probe
                // loses this one number, not the poll (#108).
                if case let .reachable(latency) = await self.probeHostShared(), asked == self.epoch {
                    self.latencyMilliseconds = latency
                }
            }
        }
    }

    func stop() {
        // Invalidate before cancelling: a task suspended past an `await` still
        // resumes and still runs its `defer`s, so the fence must stand before
        // any of that unwinds (#108).
        epoch += 1
        reachabilityGeneration += 1
        streamTask?.cancel()
        streamTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        cancelWatchdogPing()
        latencyTask?.cancel()
        latencyTask = nil
        cancelProbes()
        isRunning = false
        // Whatever we show next launch/foreground is last-known until the
        // stream confirms otherwise.
        if hasLoaded { isStale = true }
    }

    // Emptying the shared slot also stops the next asker joining an answer
    // already on its way.
    private func cancelProbes() {
        probeInFlight?.task.cancel()
        probeInFlight = nil
        connectDeadlineTask?.cancel()
        connectDeadlineTask = nil
        firstFrameLatencyTask?.cancel()
        firstFrameLatencyTask = nil
        reachabilityTask?.cancel()
        reachabilityTask = nil
    }

    private func streamOnce(handshake: URLRequest) async {
        // This dial's place in the link's history: everything below judges the
        // socket it opens, and a link that has since moved on is not its own.
        epoch += 1
        let dial = epoch
        let socket = makeSocket(handshake)
        self.socket = socket
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            if self.socket === socket { self.socket = nil }
        }

        armConnectDeadline(dial)
        defer { cancelConnectDeadline(dial) }

        let watchdog = startWatchdog(for: socket)
        defer {
            watchdog.cancel()
            // Only this dial's challenge: the `self.socket` defer is
            // registered first and so runs last, which makes this identity
            // check honest — a stream unwinding late must not cancel the
            // replacement's ping.
            if self.socket === socket { cancelWatchdogPing() }
        }

        var measured = false
        defer {
            // A dial that never produced a frame counts against the computer;
            // one that did resets the count. Fenced because a cancelled dial
            // still runs this, by which time another computer may be in place.
            if dial == epoch {
                if measured { consecutiveFailedDials = 0 } else { consecutiveFailedDials += 1 }
                streamConnectedAt = nil
            }
        }
        do {
            while !Task.isCancelled {
                let frame = try await socket.receive()
                // A frame that arrives after the link moved on describes a
                // computer nobody is looking at any more.
                guard dial == epoch else { return }
                cancelConnectDeadline(dial)
                guard case let .string(text) = frame else { continue }
                let snapshot = try JSONDecoder().decode(AgentsSnapshotMessage.self, from: Data(text.utf8))
                guard snapshot.type == "agents" else { continue }
                hasLoaded = true
                isStale = false
                isOffline = false
                isRevoked = false
                // The answer any verification was looking for (#108).
                reachabilityGeneration += 1
                reachabilityTask?.cancel()
                reachabilityTask = nil
                onEvent?(.snapshot(agents: snapshot.agents, available: snapshot.available, reason: snapshot.reason))
                if streamConnectedAt == nil { streamConnectedAt = Date() }
                // The backoff forgets only once the stream has held for a
                // while; a link that works for one frame and dies stays on
                // the slow end of the schedule (#86).
                if let since = streamConnectedAt, Date().timeIntervalSince(since) >= Self.stableStreamInterval { reconnectAttempt = 0 }
                if !measured {
                    measured = true
                    measureFirstFrameLatency(dial)
                }
            }
        } catch {
            guard !Task.isCancelled, dial == epoch else { return }
            let failure = SocketFailure(error)
            Self.logger.info("events stream ended: reason=\(failure.tag.rawValue, privacy: .public) code=\(failure.code) priorFailedDials=\(self.consecutiveFailedDials)")
            // Keep the last known agents on screen, explicitly stale —
            // dropping them here made "Needs you" blink away on every
            // network blip while the agent was still waiting.
            isStale = true
            verifyReachability(dial)
        }
    }

    // Bounded "Connecting…": if nothing has arrived by the deadline, ask the
    // host directly; no answer at all is Offline, said now, while the attempt
    // keeps going in case it is merely slow. The first frame cancels this, and
    // a probe landing after a frame — or after the link moved on — is
    // discarded: the frame is the truth.
    private func armConnectDeadline(_ dial: Int) {
        let deadline = reconnectPolicy.connectDeadline
        connectDeadlineTask?.cancel()
        connectDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled, let self else { return }
            let probe = await self.probeHostTwice(self.reachabilityGeneration)
            guard !Task.isCancelled, dial == self.epoch else { return }
            // Earned, not guessed (#86): the first dial that fails is
            // "Connecting…" or "Reconnecting"; Offline waits for the next.
            if probe == .unreachable, self.consecutiveFailedDials >= 1 { self.isOffline = true }
        }
    }

    // Only this dial's: a stream unwinding late must not cancel the
    // replacement's, and `stop()` has already ended its own.
    private func cancelConnectDeadline(_ dial: Int) {
        guard dial == epoch else { return }
        connectDeadlineTask?.cancel()
        connectDeadlineTask = nil
    }

    // The first snapshot proves the stream; the round trip behind it is the
    // measuring dial's.
    private func measureFirstFrameLatency(_ dial: Int) {
        firstFrameLatencyTask?.cancel()
        firstFrameLatencyTask = Task { [weak self] in
            guard let self, case let .reachable(latency) = await self.probeHostShared() else { return }
            guard dial == self.epoch else { return }
            self.latencyMilliseconds = latency
        }
    }

    // A WebSocket drop and an HTTP 401 look alike here, so ask the host
    // directly before deciding; the same probe says whether the computer
    // answers at all (#50). It runs beside the redial, never in front of it:
    // waiting out the double probe (up to 11.5 s) first made the app miss
    // every short good window on a WiFi link that goes deaf for seconds at a
    // time (three cold reviews, 2026-09-02 night). One verification per
    // generation, not per dial: on a computer that black-holes each question
    // waits out its 5 s timeout while the redial arrives in 8–10 s, so
    // restarting here meant the pair never finished and Offline never came.
    private func verifyReachability(_ dial: Int) {
        guard reachabilityTask == nil else { return }
        let generation = reachabilityGeneration
        reachabilityTask = Task { [weak self] in
            guard let self else { return }
            let probe = await self.probeHostTwice(generation)
            defer { if generation == self.reachabilityGeneration { self.reachabilityTask = nil } }
            guard generation == self.reachabilityGeneration else { return }
            switch probe {
            case .rejected:
                self.isRevoked = true
                self.isOffline = false
                self.hasLoaded = true
                self.isStale = false
                self.onEvent?(.revoked(reason: "This iPhone is no longer paired with this computer. Pair it again to reconnect."))
                self.stop()
            case let .reachable(latency):
                self.isOffline = false
                // The number is a measurement, so it is the dial's.
                if dial == self.epoch { self.latencyMilliseconds = latency }
            case .unreachable:
                if self.isStale, self.consecutiveFailedDials >= 2 { self.isOffline = true }
            // Never really asked, so nothing is known; the next drop verifies.
            case .superseded: break
            }
        }
    }

    // The watchdog for one socket (#86, #107). Snapshots arrive on change
    // only, so a dead socket looks exactly like a quiet evening: challenge
    // it with a ping after `pingAfterIdle`, cycle it at `cycleAfterIdle`.
    // The ping is never awaited in this loop — awaiting it inline let a
    // send that suspended keep the loop from ever reaching the cycle check,
    // so a socket 51 s idle had been pinged once and cancelled never.
    private func startWatchdog(for socket: any HostEventsSocketing) -> Task<Void, Never> {
        let policy = watchdogPolicy
        return Task { [weak self, weak socket] in
            // Whether this quiet period has already been challenged. Reset
            // by activity; the pending send itself is owned by the link, not
            // by the period that started it.
            var challenged = false
            while !Task.isCancelled {
                try? await Task.sleep(for: policy.pollInterval)
                guard !Task.isCancelled, let self, let socket else { return }
                let idle = Date().timeIntervalSince(socket.lastActivity)
                if idle >= policy.cycleAfterIdle {
                    cancelWatchdogPing()
                    socket.cancel(with: .goingAway, reason: nil)
                    return
                }
                guard idle >= policy.pingAfterIdle else {
                    challenged = false
                    continue
                }
                guard !challenged else { continue }
                challenged = true
                challengeQuietSocket(socket)
            }
        }
    }

    // One challenge in flight per link, and it stays this link's until the
    // send actually finishes. A send that ignores cancellation must not be
    // orphaned by a blip of activity and then multiplied by the next quiet
    // period; cancelling the socket is what releases the real one (#107).
    private func challengeQuietSocket(_ socket: any HostEventsSocketing) {
        guard watchdogPing == nil else { return }
        watchdogPingGeneration += 1
        let generation = watchdogPingGeneration
        watchdogPing = Task { [weak self, weak socket] in
            try? await socket?.ping()
            guard let self, watchdogPingGeneration == generation else { return }
            watchdogPing = nil
        }
    }

    private func cancelWatchdogPing() {
        watchdogPing?.cancel()
        watchdogPing = nil
        watchdogPingGeneration += 1
    }

    // Offline is said only after two misses a moment apart: one slow
    // round trip on a jittery WiFi hop must not flip a live computer to
    // "isn't answering" (owner-felt, 2026-09-02 evening). Failed redials in
    // between do not stop it — they are the case it exists to decide — but a
    // computer that has since spoken, or a link that has been stopped or
    // pointed elsewhere, does.
    private func probeHostTwice(_ generation: Int) async -> HostProbe {
        let first = await probeHostChecked(generation)
        guard first == .unreachable, !Task.isCancelled, generation == reachabilityGeneration else { return first }
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled, generation == reachabilityGeneration else { return first }
        return await probeHostChecked(generation)
    }

    // One check. A request the link itself cancelled says nothing about the
    // computer, so it is re-asked in the flight that displaced it rather than
    // counted as a miss: one timeout plus one cancelled request used to earn
    // Offline (#108). Bounded — each attempt is a real round trip, and a link
    // that keeps displacing them verifies again on its next drop.
    private func probeHostChecked(_ generation: Int) async -> HostProbe {
        for _ in 0..<Self.supersededProbeAttempts {
            let probe = await probeHostShared()
            guard probe == .superseded, !Task.isCancelled, generation == reachabilityGeneration else { return probe }
        }
        return .superseded
    }

    private enum HostProbe: Equatable {
        // A definite 401: the credential is dead.
        case rejected
        // The host answered (any other status), in this many milliseconds.
        case reachable(latencyMilliseconds: Int)
        // No answer at the connection level: asleep, gone, or we are offline.
        case unreachable
        // The link abandoned the request before the computer could answer.
        case superseded
    }

    // Bounded tightly: this runs on every stream drop, including the
    // ordinary background→foreground cycle, and with the default 60 s
    // timeout a half-dead connection after resume held the whole reconnect
    // for a minute (owner-reported). Anything but a definite 401 keeps the
    // stream retrying; only a connection-level failure marks the host
    // offline.
    private func probeHost(_ origin: Int) async -> HostProbe {
        guard let client, let request = client.request("GET", "/api/host", timeout: 5) else { return .unreachable }
        let started = Date()
        // An answer stands even if cancellation arrived behind it; a failure
        // under cancellation is our doing, not the computer's (#108).
        guard case let .answered(status, data, _) = await client.send(request) else {
            return Task.isCancelled ? .superseded : .unreachable
        }
        if status == 401 { return .rejected }
        // Last writer wins here, so an answer the link has already overtaken
        // must not be the one that wins (#108).
        if status == 200, origin == epoch,
           let answer = try? JSONDecoder().decode(HostAnswer.self, from: data) {
            let answered = ConnectionPath(path: answer.connection?.path, relay: answer.connection?.relay)
            if answered != path { path = answered }
        }
        return .reachable(latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }

    // Single-flight: the connect deadline, the drop path and the latency poll
    // all ask the same question; on a bad link they used to ask it four times
    // at once (#86). Keyed by the epoch it was put in, so an asker in a newer
    // one puts its own rather than reading an answer that predates its stream
    // as that stream's; the displaced question is cancelled, and the identity
    // check below clears its own slot or nothing (#108).
    private func probeHostShared() async -> HostProbe {
        let origin = epoch
        if let inFlight = probeInFlight {
            if inFlight.origin == origin { return await inFlight.task.value }
            inFlight.task.cancel()
        }
        let task = Task { [weak self] in
            await self?.probeHost(origin) ?? .unreachable
        }
        probeInFlight = (origin, task)
        defer { if probeInFlight?.task == task { probeInFlight = nil } }
        return await task.value
    }

    private struct HostAnswer: Decodable {
        struct Connection: Decodable {
            let path: String
            let relay: String?
        }

        let connection: Connection?
    }
}

private struct AgentsSnapshotMessage: Decodable {
    let type: String
    let available: Bool
    let reason: String?
    let agents: [AgentSummary]
}

// The events socket as this link uses it: the same seam the terminal
// transport has for NetworkWebSocketTask (#70, #99).
protocol HostEventsSocketing: AnyObject, Sendable {
    // When the last frame of any kind arrived — the watchdog's idle clock.
    var lastActivity: Date { get }

    func resume()
    func receive() async throws -> URLSessionWebSocketTask.Message
    func ping() async throws
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension NetworkWebSocketTask: HostEventsSocketing {}
