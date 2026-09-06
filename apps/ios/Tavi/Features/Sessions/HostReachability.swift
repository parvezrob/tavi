import Foundation

// "Does this computer answer at all?" — the one question the events link asks
// over HTTP when its socket says nothing useful, with the single-flight and
// the two-misses rules that decide what an answer is worth (#50, #86, #108).
// Carved out of `HostConnection` unchanged (#101, #111 P4): the link still
// owns the verdict, this owns the asking.
@MainActor
final class HostReachability {
    enum Answer: Equatable {
        // A definite 401: the credential is dead.
        case rejected
        // The host answered (any other status), in this many milliseconds.
        case reachable(latencyMilliseconds: Int)
        // No answer at the connection level: asleep, gone, or we are offline.
        case unreachable
        // The link abandoned the request before the computer could answer.
        case superseded
    }

    private static let supersededAttempts = 3

    private let timing: ConnectionTiming
    // One probe in flight however many askers (#86); keyed by the epoch that
    // asked it.
    private var inFlight: (origin: Int, task: Task<Answer, Never>)?

    // The link's door to the computer and its two fences, read at the moment
    // each question is asked rather than captured once: a link that has been
    // reconfigured must be asked about the computer it points at now.
    private var client: () -> HostClient? = { nil }
    private var epoch: () -> Int = { 0 }
    private var generation: () -> Int = { 0 }
    private var onPath: (ConnectionPath) -> Void = { _ in }
    // Recorded here rather than at the call sites: `ask()` is single-flight,
    // so several askers share one answer, and recording where it is read
    // would count one round trip several times (#111).
    private var onAnswer: (RecoveryLog.Probe, Int) -> Void = { _, _ in }

    init(timing: ConnectionTiming) {
        self.timing = timing
    }

    func install(
        client: @escaping () -> HostClient?,
        epoch: @escaping () -> Int,
        generation: @escaping () -> Int,
        onPath: @escaping (ConnectionPath) -> Void,
        onAnswer: @escaping (RecoveryLog.Probe, Int) -> Void
    ) {
        self.client = client
        self.epoch = epoch
        self.generation = generation
        self.onPath = onPath
        self.onAnswer = onAnswer
    }

    func cancel() {
        inFlight?.task.cancel()
        inFlight = nil
    }

    // Offline is said only after two misses a moment apart: one slow round
    // trip on a jittery WiFi hop must not flip a live computer to "isn't
    // answering" (owner-felt, 2026-09-02). A computer that has since spoken,
    // or a link stopped or pointed elsewhere, ends the question early.
    func askTwice(_ generation: Int) async -> Answer {
        let first = await askChecked(generation)
        guard first == .unreachable, !Task.isCancelled, generation == self.generation() else { return first }
        try? await timing.sleep(.seconds(1.5))
        guard !Task.isCancelled, generation == self.generation() else { return first }
        return await askChecked(generation)
    }

    // Single-flight: the connect deadline, the drop path and the latency poll
    // all ask the same question; on a bad link they used to ask it four times
    // at once (#86). An asker in a newer epoch displaces an older question
    // rather than reading its answer as its own (#108).
    func ask() async -> Answer {
        let origin = epoch()
        if let inFlight {
            if inFlight.origin == origin { return await inFlight.task.value }
            inFlight.task.cancel()
        }
        let task = Task { [weak self] in
            await self?.probe(origin) ?? .unreachable
        }
        inFlight = (origin, task)
        defer { if inFlight?.task == task { inFlight = nil } }
        return await task.value
    }

    // A request the link itself cancelled says nothing about the computer,
    // so it is re-asked in the flight that displaced it rather than counted
    // as a miss: one timeout plus one cancelled request used to earn Offline
    // (#108). Bounded; a link that keeps displacing them verifies next drop.
    private func askChecked(_ generation: Int) async -> Answer {
        for _ in 0..<Self.supersededAttempts {
            let answer = await ask()
            guard answer == .superseded, !Task.isCancelled, generation == self.generation() else { return answer }
        }
        return .superseded
    }

    // Bounded tightly: this runs on every stream drop, including the
    // ordinary background→foreground cycle, and with the default 60 s
    // timeout a half-dead connection after resume held the whole reconnect
    // for a minute (owner-reported). Anything but a definite 401 keeps the
    // stream retrying; only a connection-level failure marks the host
    // offline.
    private func probe(_ origin: Int) async -> Answer {
        // Nothing was asked of the computer here, so nothing is recorded.
        guard let client = client(), let request = client.request("GET", "/api/host", timeout: 5) else { return .unreachable }
        let started = timing.now()
        // A failure under cancellation is our doing, not the computer's (#108).
        guard case let .answered(status, data, _) = await client.send(request) else {
            if Task.isCancelled { return .superseded }
            onAnswer(.unreachable, origin)
            return .unreachable
        }
        if status == 401 {
            onAnswer(.rejected, origin)
            return .rejected
        }
        // An answer the link has already overtaken must not write the path (#108).
        if status == 200, origin == epoch(),
           let answer = try? JSONDecoder().decode(HostAnswer.self, from: data) {
            onPath(ConnectionPath(path: answer.connection?.path, relay: answer.connection?.relay))
        }
        onAnswer(.reachable, origin)
        return .reachable(latencyMilliseconds: Int(started.milliseconds(to: timing.now())))
    }
}

// `GET /api/host`, as much of it as this question needs.
private struct HostAnswer: Decodable {
    let connection: HostAnswerConnection?
}

private struct HostAnswerConnection: Decodable {
    let path: String
    let relay: String?
}
