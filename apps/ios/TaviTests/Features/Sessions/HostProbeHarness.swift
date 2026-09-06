import Foundation
@testable import Tavi

// The two seams #108 needs held open: a computer that answers only when the
// test says so, and a dial that stays open however hard the link tries to
// end it. Together they put a probe or a socket in exactly the window where
// it can reach a link that has already moved on — with no guessed sleeps.

// Only timing is shortened; every rule the link applies to a probe is the
// production one.
enum ProbeSchedule {
    static let quickRedial = ReconnectPolicy(
        initialDelay: .milliseconds(10),
        maximumDelay: .milliseconds(10),
        multiplier: 1,
        connectDeadline: .seconds(30)
    )
    static let quickDeadline = ReconnectPolicy(
        initialDelay: .milliseconds(10),
        maximumDelay: .milliseconds(10),
        multiplier: 1,
        connectDeadline: .milliseconds(30)
    )
    // Will not redial inside a test, for the cases about one dial's own
    // accounting rather than about its replacement.
    static let singleDial = ReconnectPolicy(
        initialDelay: .seconds(30),
        maximumDelay: .seconds(30),
        multiplier: 1,
        connectDeadline: .seconds(30)
    )
    // One quick redial and then a pause: two dials that produced no frame,
    // then an epoch that stays still long enough to hold a probe open in it.
    static let oneRedial = ReconnectPolicy(
        initialDelay: .milliseconds(10),
        maximumDelay: .seconds(30),
        multiplier: 3_000,
        connectDeadline: .seconds(30)
    )
    // One quick redial, then one that lands well after a verification's 1.5 s
    // gap, so its connect deadline displaces the second question rather than
    // the first.
    static let lateRedial = ReconnectPolicy(
        initialDelay: .milliseconds(10),
        maximumDelay: .seconds(3),
        multiplier: 300,
        connectDeadline: .milliseconds(30)
    )
}

// The directory's sink, so a test can say what reached it.
@MainActor
final class ProbeEvents {
    var snapshots: [[AgentSummary]] = []
    var revocations: [String] = []

    func note(_ event: HostConnectionEvent) {
        switch event {
        case let .snapshot(agents, _, _): snapshots.append(agents)
        case let .revoked(reason): revocations.append(reason)
        }
    }
}

let probeStudio = "https://studio.tailnet.ts.net"
let probeLaptop = "https://laptop.tailnet.ts.net"

@MainActor
func probeLink(
    _ sockets: HeldEventsSockets,
    host: GatedHost,
    policy: ReconnectPolicy = ProbeSchedule.quickRedial
) throws -> (HostConnection, ProbeEvents) {
    let connection = HostConnection(transport: host.transport, makeSocket: sockets.make, reconnectPolicy: policy)
    let events = ProbeEvents()
    connection.configure(host: try Fixtures.hostEndpoint(probeStudio), credential: "secret") { events.note($0) }
    return (connection, events)
}

// The same computer sheet, a different computer: one this phone has a
// different credential for.
@MainActor
func probeReconfigure(_ connection: HostConnection, into events: ProbeEvents) throws {
    connection.configure(host: try Fixtures.hostEndpoint(probeLaptop), credential: "other") { events.note($0) }
}

// A negative assertion has to prove the released answer had its whole chance
// to land. Every task involved is on this actor, so yielding hands each of
// them the main actor in turn.
@MainActor
func drainProbes() async {
    for _ in 0..<50 { await Task.yield() }
}

// A paired computer whose answers the test releases by hand. Every probe the
// events link makes is a `GET /api/host` through this transport, so holding
// one here holds the probe across a `stop()`, a reconfiguration, or a whole
// redial.
final class GatedHost: @unchecked Sendable {
    enum Answer: Sendable {
        // A status with the JSON body the host sent beside it.
        case json(Int, String)
        // Nothing came back: asleep, off the tailnet, or this phone is offline.
        case silence
        // The request never reached the computer because its task was
        // cancelled, which is what URLSession reports when the link
        // supersedes one.
        case cancelled
    }

    private typealias Held = (call: Int, continuation: CheckedContinuation<Answer, Never>)

    private let lock = NSLock()
    private let cancellable: Bool
    private var waiting: [Held] = []
    private var queued: [Answer]
    private var nextCall = 0
    private var started = 0
    private var finished = 0
    private var cancelled = 0
    private var cancelledBeforeParking: Set<Int> = []

    // Answers given without suspending, oldest first; a call past the script
    // waits for `release`. `cancellable` makes a held call answer the moment
    // its task is cancelled instead of ignoring cancellation.
    init(script: [Answer] = [], cancellable: Bool = false) {
        queued = script
        self.cancellable = cancellable
    }

    // The facts a test synchronises on: calls reached, answered, cancelled,
    // and still being held.
    var callsStarted: Int { lock.withLock { started } }
    var callsFinished: Int { lock.withLock { finished } }
    var callsCancelled: Int { lock.withLock { cancelled } }
    var callsWaiting: Int { lock.withLock { waiting.count } }

    // Answers the call that has waited longest, or the next one to arrive.
    func release(_ answer: Answer) {
        let held = lock.withLock { () -> Held? in
            guard !waiting.isEmpty else {
                queued.append(answer)
                return nil
            }
            return waiting.removeFirst()
        }
        held?.continuation.resume(returning: answer)
    }

    // Frees every call still waiting — all of them, so a test that fails an
    // assertion early still leaves no continuation behind.
    func releaseAll() {
        let held = lock.withLock { () -> [Held] in
            defer { waiting.removeAll() }
            return waiting
        }
        held.forEach { $0.continuation.resume(returning: .silence) }
    }

    // `onCancel` can run before the call has parked, so a cancellation that
    // arrives first is left for the parking side to find.
    private func park(_ call: Int) async -> Answer {
        await withCheckedContinuation { (continuation: CheckedContinuation<Answer, Never>) in
            let ready = lock.withLock { () -> Answer? in
                if cancelledBeforeParking.remove(call) != nil { return .cancelled }
                guard queued.isEmpty else { return queued.removeFirst() }
                waiting.append((call, continuation))
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    private func awaitAnswer(_ call: Int) async -> Answer {
        guard cancellable else { return await park(call) }
        return await withTaskCancellationHandler {
            await park(call)
        } onCancel: {
            abandon(call)
        }
    }

    private func abandon(_ call: Int) {
        let held = lock.withLock { () -> Held? in
            guard let index = waiting.firstIndex(where: { $0.call == call }) else {
                cancelledBeforeParking.insert(call)
                return nil
            }
            return waiting.remove(at: index)
        }
        held?.continuation.resume(returning: .cancelled)
    }

    var transport: HostClient.Transport {
        { [self] request in
            let call = lock.withLock { () -> Int in
                started += 1
                nextCall += 1
                return nextCall
            }
            let answer = await awaitAnswer(call)
            switch answer {
            case .cancelled:
                lock.withLock { cancelled += 1 }
                throw URLError(.cancelled)
            case .silence:
                lock.withLock { finished += 1 }
                throw URLError(.cannotConnectToHost)
            case let .json(status, body):
                lock.withLock { finished += 1 }
                guard let url = request.url,
                      let response = HTTPURLResponse(
                          url: url,
                          statusCode: status,
                          httpVersion: nil,
                          headerFields: ["Content-Type": "application/json"]
                      ) else {
                    throw URLError(.badServerResponse)
                }
                return (Data(body.utf8), response as URLResponse)
            }
        }
    }
}

// A scripted events socket whose `hold` suspends `receive()` on a
// continuation only the test resumes. Cancelling the stream cannot make it
// return — which is the real shape of the defect: a dial left open while the
// link is stopped or pointed at another computer, and then unwinding late.
final class HeldEventsSocket: HostEventsSocketing, @unchecked Sendable {
    enum Line: Sendable {
        case frame(String)
        case drop
        // Wait for the test; then read on into whatever comes next.
        case hold
    }

    private let lock = NSLock()
    private var script: [Line]
    private var holds: [CheckedContinuation<Void, Never>] = []
    private var normalCloseCount = 0

    init(_ script: Line...) {
        self.script = script
    }

    var lastActivity: ContinuousClock.Instant { ContinuousClock().now }

    // Closing the socket the ordinary way is the last thing `streamOnce`
    // does, so this is a test's proof that a dial has fully unwound —
    // including the `defer`s that are the point of the exercise.
    var normalCloses: Int { lock.withLock { normalCloseCount } }

    // Lets go of every held `receive()`, so teardown leaves nothing behind.
    func releaseHolds() {
        let held = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { holds.removeAll() }
            return holds
        }
        held.forEach { $0.resume() }
    }

    func resume() {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        while true {
            let next = lock.withLock { script.isEmpty ? Line.hold : script.removeFirst() }
            switch next {
            case let .frame(text):
                return .string(text)
            case .drop:
                throw URLError(.networkConnectionLost)
            case .hold:
                await withCheckedContinuation { continuation in
                    lock.withLock { holds.append(continuation) }
                }
                // Released. A script with more in it reads on; one that ends
                // here ends the dial rather than holding again.
                if lock.withLock({ script.isEmpty }) { throw CancellationError() }
            }
        }
    }

    func ping() async throws {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard closeCode == .normalClosure else { return }
        lock.withLock { normalCloseCount += 1 }
    }
}

// One socket per dial, in order; a dial past the script gets one that holds,
// so a test's redial schedule never runs away from it.
final class HeldEventsSockets: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [HeldEventsSocket]
    private var handed: [HeldEventsSocket] = []

    init(_ queued: HeldEventsSocket...) {
        self.queued = queued
    }

    var dials: Int { lock.withLock { handed.count } }

    @Sendable
    func make(_ request: URLRequest) -> any HostEventsSocketing {
        lock.withLock { () -> any HostEventsSocketing in
            let socket = queued.isEmpty ? HeldEventsSocket(.hold) : queued.removeFirst()
            handed.append(socket)
            return socket
        }
    }

    func releaseHolds() {
        lock.withLock { handed }.forEach { $0.releaseHolds() }
    }
}
