import Foundation
import Observation
import os

// How the phone's packets reach the computer, per the computer's own
// Tailscale (#86 / #84): said in words, never coloured as a problem — a
// relay is slower and still private.
enum ConnectionPath: Equatable, Sendable {
    case direct
    case relay(String?)
    case unknown

    init(path: String?, relay: String?) {
        switch path {
        case "direct": self = .direct
        case "relay": self = .relay(relay.flatMap { $0.isEmpty ? nil : $0 })
        default: self = .unknown
        }
    }

    // The word that joins "Live · 7 ms" on the header; nothing for direct,
    // which is the ordinary case and needs no comment.
    var headerSuffix: String? {
        if case .relay = self { return "relay" }
        return nil
    }

    // The sentence on the computer sheet's "Right now" footer.
    var sentence: String? {
        switch self {
        case .direct: "Direct to this computer — the fastest path there is."
        case let .relay(region): "Through a Tailscale relay\(region.map { " (\($0))" } ?? "") — slower, still private. Usual on mobile networks; at home it means the two devices cannot see each other directly on the WiFi."
        case .unknown: nil
        }
    }
}

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
// directory; what the link is doing is this type's own truth.
@MainActor
@Observable
final class HostConnection {
    private static let logger = Logger(subsystem: "com.farfield.tavi", category: "agents.directory")
    private static let eventsProtocol = "tavi.events.v1"
    // Retry cadence for the events stream. A computer that is asleep or off
    // the tailnet is dialled again at 2, 4, 8, 16, then every 30 s — not
    // every 2 s for hours (owner-felt, 2026-09-02: robin-PC unplugged). The
    // connect deadline bounds "Connecting…": a peer that has said nothing
    // after 5 s is probed, and no answer means Offline — the phone never
    // waits out a silent handshake to admit it.
    private static let reconnectPolicy = ReconnectPolicy(
        initialDelay: .seconds(2),
        // Ten, not thirty: a person is looking at this screen, and a link
        // that comes back should be caught within seconds (#86).
        maximumDelay: .seconds(10),
        multiplier: 2,
        connectDeadline: .seconds(5)
    )
    private static let latencyInterval: Duration = .seconds(30)
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
    private var onEvent: ((HostConnectionEvent) -> Void)?
    private var reconnectAttempt = 0
    private var streamTask: Task<Void, Never>?
    // The live events socket. `stop()` must close it itself: cancelling the
    // task alone leaves `receive()` waiting for the host's next frame, and a
    // quiet host never sends one — the connection, its socket and its
    // buffers then live on (measured 2026-09-02: 242 directories after 200
    // home → terminal → home trips, ~140 KB and one host stream each).
    // Network.framework, not URLSession: see NetworkWebSocketTask (#70).
    private var socket: NetworkWebSocketTask?
    private var latencyTask: Task<Void, Never>?
    // Reconnect coordination (#86, PRD §7.13): one probe in flight however
    // many askers; Offline only after two dials in a row produced no frame;
    // the backoff resets only once the stream has been up for a while.
    private var probeInFlight: Task<HostProbe, Never>?
    private var consecutiveFailedDials = 0
    private var streamConnectedAt: Date?

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
        guard streamTask == nil, !isRevoked, let host, !credential.isEmpty else { return }
        guard let eventsURL = try? host.eventsURL() else { return }
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
        let credential = credential
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.streamOnce(eventsURL: eventsURL, credential: credential)
                guard !Task.isCancelled else { return }
                self.reconnectAttempt += 1
                try? await Task.sleep(for: Self.reconnectPolicy.delay(forAttempt: self.reconnectAttempt))
            }
        }
        latencyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.latencyInterval)
                guard !Task.isCancelled, let self else { return }
                guard self.hasLoaded, !self.isStale else { continue }
                if case let .reachable(latency) = await self.probeHostShared() {
                    self.latencyMilliseconds = latency
                }
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        latencyTask?.cancel()
        latencyTask = nil
        isRunning = false
        // Whatever we show next launch/foreground is last-known until the
        // stream confirms otherwise.
        if hasLoaded { isStale = true }
    }

    private func streamOnce(eventsURL: URL, credential: String) async {
        var request = URLRequest(url: eventsURL)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.eventsProtocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        // A handshake that gets no answer must fail on its own clock, not
        // the system's minute-long default: the deadline below decides what
        // the home says, this decides when the attempt is abandoned.
        // Eight seconds: a handshake through a relay takes about one; a
        // radio that is still waking up must fail fast so the redial runs.
        request.timeoutInterval = 8
        let socket = NetworkWebSocketTask(request: request)
        self.socket = socket
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            if self.socket === socket { self.socket = nil }
        }

        // Bounded "Connecting…": if nothing has arrived by the deadline,
        // ask the host directly; no answer at all is Offline, said now,
        // while the attempt keeps going in case it is merely slow. The
        // first frame cancels this, and a probe that lands after a frame
        // is discarded — the frame is the truth.
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.reconnectPolicy.connectDeadline)
            guard !Task.isCancelled, let self else { return }
            let probe = await self.probeHostTwice()
            guard !Task.isCancelled else { return }
            // Earned, not guessed (#86): the first dial that fails is
            // "Connecting…" or "Reconnecting"; Offline waits for the next.
            if probe == .unreachable, self.consecutiveFailedDials >= 1 { self.isOffline = true }
        }
        defer { deadline.cancel() }

        // Snapshots arrive on change only, so a dead socket looks exactly
        // like a quiet evening: ping after 30 s of silence, cycle at 45 s
        // (#86). The host's WebSocket server answers pings on its own.
        let watchdog = Task { [weak socket] in
            var pinged = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let socket else { return }
                let idle = Date().timeIntervalSince(socket.lastActivity)
                if idle >= 45 {
                    socket.cancel(with: .goingAway, reason: nil)
                    return
                }
                if idle >= 30, !pinged {
                    pinged = true
                    try? await socket.ping()
                } else if idle < 30 {
                    pinged = false
                }
            }
        }
        defer { watchdog.cancel() }

        var measured = false
        defer {
            // A dial that never produced a frame counts against the
            // computer; one that did resets the count.
            if measured { consecutiveFailedDials = 0 } else { consecutiveFailedDials += 1 }
            streamConnectedAt = nil
        }
        do {
            while !Task.isCancelled {
                let frame = try await socket.receive()
                deadline.cancel()
                guard case let .string(text) = frame else { continue }
                let snapshot = try JSONDecoder().decode(AgentsSnapshotMessage.self, from: Data(text.utf8))
                guard snapshot.type == "agents" else { continue }
                hasLoaded = true
                isStale = false
                isOffline = false
                isRevoked = false
                onEvent?(.snapshot(agents: snapshot.agents, available: snapshot.available, reason: snapshot.reason))
                if streamConnectedAt == nil { streamConnectedAt = Date() }
                // The backoff forgets only once the stream has held for a
                // while; a link that works for one frame and dies stays on
                // the slow end of the schedule (#86).
                if let since = streamConnectedAt, Date().timeIntervalSince(since) >= Self.stableStreamInterval { reconnectAttempt = 0 }
                if !measured {
                    // The first snapshot proves the stream; the round trip
                    // the header shows is measured right behind it.
                    measured = true
                    Task { [weak self] in
                        guard let self, case let .reachable(latency) = await self.probeHostShared() else { return }
                        self.latencyMilliseconds = latency
                    }
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.info("events stream ended: \(error.localizedDescription)")
            // Keep the last known agents on screen, explicitly stale —
            // dropping them here made "Needs you" blink away on every
            // network blip while the agent was still waiting.
            isStale = true
            // Unless the host is telling us this credential is dead: a
            // WebSocket drop and an HTTP 401 look alike here, so ask the
            // host directly before deciding. The same probe says whether
            // the computer answers at all (#50): "reconnecting" and
            // "offline" are different headers on the home.
            // The probe runs beside the redial, never in front of it: the
            // reconnect backoff starts the moment the stream drops. Waiting
            // out the double probe here (up to 11.5 s) before redialing made
            // the app miss every short good window on a WiFi link that goes
            // deaf for seconds at a time — the old single 3 s probe never
            // did (three cold reviews, 2026-09-02 night). A snapshot that
            // lands before the probe answers wins: the probe then says
            // nothing about "offline".
            Task { [weak self] in
                guard let self else { return }
                switch await self.probeHostTwice() {
                case .rejected:
                    self.isRevoked = true
                    self.isOffline = false
                    self.hasLoaded = true
                    self.isStale = false
                    self.onEvent?(.revoked(reason: "This iPhone is no longer paired with this computer. Pair it again to reconnect."))
                    self.stop()
                case let .reachable(latency):
                    self.isOffline = false
                    self.latencyMilliseconds = latency
                case .unreachable:
                    if self.isStale, self.consecutiveFailedDials >= 2 { self.isOffline = true }
                }
            }
        }
    }

    // Offline is said only after two misses a moment apart: one slow
    // round trip on a jittery WiFi hop must not flip a live computer to
    // "isn't answering" (owner-felt, 2026-09-02 evening).
    private func probeHostTwice() async -> HostProbe {
        let first = await probeHostShared()
        guard first == .unreachable, !Task.isCancelled else { return first }
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled else { return first }
        return await probeHostShared()
    }

    private enum HostProbe: Equatable {
        // A definite 401: the credential is dead.
        case rejected
        // The host answered (any other status), in this many milliseconds.
        case reachable(latencyMilliseconds: Int)
        // No answer at the connection level: asleep, gone, or we are offline.
        case unreachable
    }

    // Bounded tightly: this runs on every stream drop, including the
    // ordinary background→foreground cycle, and with the default 60 s
    // timeout a half-dead connection after resume held the whole reconnect
    // for a minute (owner-reported). Anything but a definite 401 keeps the
    // stream retrying; only a connection-level failure marks the host
    // offline.
    private func probeHost() async -> HostProbe {
        guard let host, !credential.isEmpty,
              var components = URLComponents(url: host.baseURL, resolvingAgainstBaseURL: false) else { return .unreachable }
        components.path = "/api/host"
        guard let url = components.url else { return .unreachable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        let started = Date()
        guard let (data, response) = try? await HostSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .unreachable }
        if status == 401 { return .rejected }
        if status == 200, let answer = try? JSONDecoder().decode(HostAnswer.self, from: data) {
            let answered = ConnectionPath(path: answer.connection?.path, relay: answer.connection?.relay)
            if answered != path { path = answered }
        }
        return .reachable(latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }

    // Single-flight: the connect deadline, the drop path and the latency
    // poll all ask the same question; on a bad link they used to ask it
    // four times at once (#86).
    private func probeHostShared() async -> HostProbe {
        if let probeInFlight { return await probeInFlight.value }
        let task = Task { [weak self] in
            await self?.probeHost() ?? .unreachable
        }
        probeInFlight = task
        defer { if probeInFlight == task { probeInFlight = nil } }
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
