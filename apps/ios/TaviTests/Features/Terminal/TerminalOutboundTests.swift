import Foundation
@testable import Tavi
import Testing

// The terminal's outbound path: one send in flight, whatever arrives
// meanwhile queued behind it, typing coalesced so a fast typist costs one
// frame, and a full queue refused out loud rather than dropped (#96).
@MainActor
struct TerminalOutboundTests {
    private final class Recorder {
        var outcomes: [TerminalOutbound.Outcome] = []
    }

    // Which generation the controller would call current, moved by the test
    // while a send is in flight.
    private final class LiveGeneration {
        var value = 1
    }

    private static func outbound(
        _ transport: GatedTransport,
        liveGeneration: @escaping @MainActor (Int) -> Bool = { _ in true }
    ) -> (TerminalOutbound, Recorder) {
        let outbound = TerminalOutbound(client: transport)
        let recorder = Recorder()
        outbound.installGenerationCheck(liveGeneration)
        outbound.installOutcomeConsumer { recorder.outcomes.append($0) }
        return (outbound, recorder)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the condition never became true")
    }

    // MARK: - Coalescing

    @Test func typingBehindASendInFlightLeavesAsOneFrame() async throws {
        let transport = GatedTransport()
        let (outbound, _) = Self.outbound(transport)
        outbound.submitInput(Data("a".utf8), generation: 1, canCoalesce: true)
        try await waitUntil { await transport.inputs.count == 1 }
        outbound.submitInput(Data("b".utf8), generation: 1, canCoalesce: true)
        outbound.submitInput(Data("c".utf8), generation: 1, canCoalesce: true)
        await transport.release()
        try await waitUntil { await transport.inputs.count == 2 }
        #expect(await transport.inputs == ["a", "bc"])
    }

    // A paste or a quick key is not typing: it keeps its own frame so the
    // agent sees the same bytes in the same shape the person sent them.
    @Test func aChunkThatMayNotCoalesceKeepsItsOwnFrame() async throws {
        let transport = GatedTransport()
        let (outbound, _) = Self.outbound(transport)
        outbound.submitInput(Data("a".utf8), generation: 1, canCoalesce: true)
        try await waitUntil { await transport.inputs.count == 1 }
        outbound.submitInput(Data("b".utf8), generation: 1, canCoalesce: false)
        outbound.submitInput(Data("c".utf8), generation: 1, canCoalesce: false)
        await transport.release()
        try await waitUntil { await transport.inputs.count == 2 }
        await transport.release()
        try await waitUntil { await transport.inputs.count == 3 }
        #expect(await transport.inputs == ["a", "b", "c"])
    }

    @Test func coalescingStopsAtFourKilobytesSoOneFrameStaysASensibleSize() async throws {
        let transport = GatedTransport()
        let (outbound, _) = Self.outbound(transport)
        outbound.submitInput(Data("a".utf8), generation: 1, canCoalesce: true)
        try await waitUntil { await transport.inputs.count == 1 }
        outbound.submitInput(Self.filler(3_000), generation: 1, canCoalesce: true)
        outbound.submitInput(Self.filler(3_000), generation: 1, canCoalesce: true)
        await transport.release()
        try await waitUntil { await transport.inputs.count == 2 }
        #expect(await transport.inputs.last?.count == 3_000)
    }

    // MARK: - Backpressure

    // 16 × 4 KB is exactly the 64 KB the queue holds; the next is refused.
    @Test(arguments: zip([16, 17], [false, true]))
    func aQueueRefusesOnlyOnceItIsFull(chunks: Int, refused: Bool) async throws {
        let transport = GatedTransport()
        let (outbound, recorder) = Self.outbound(transport)
        outbound.submitInput(Data("a".utf8), generation: 1, canCoalesce: false)
        try await waitUntil { await transport.inputs.count == 1 }
        for _ in 0..<chunks {
            outbound.submitInput(Self.filler(4_096), generation: 1, canCoalesce: false)
        }
        #expect(recorder.outcomes.contains { if case .backedUp = $0 { return true } else { return false } } == refused)
    }

    // Refused, never dropped: a keystroke the queue would not take must not
    // reach the agent later out of order either.
    @Test func aRefusedKeystrokeIsNeverSentBehindTheQueue() async throws {
        let transport = GatedTransport()
        let (outbound, _) = Self.outbound(transport)
        outbound.submitInput(Data("a".utf8), generation: 1, canCoalesce: false)
        try await waitUntil { await transport.inputs.count == 1 }
        for _ in 0..<17 {
            outbound.submitInput(Self.filler(4_096), generation: 1, canCoalesce: false)
        }
        #expect(await transport.inputs.count == 1)
    }

    // MARK: - Draining

    @Test func anEmptyQueueSaysSoSoADeferredResizeCanGo() async throws {
        let transport = GatedTransport()
        let (outbound, recorder) = Self.outbound(transport)
        outbound.submitInput(Data("a".utf8), generation: 1, canCoalesce: true)
        try await waitUntil { await transport.inputs.count == 1 }
        await transport.release()
        try await waitUntil { recorder.outcomes.contains { if case .drained = $0 { return true } else { return false } } }
        #expect(outbound.isIdle)
    }

    // A connection change clears the queue: bytes accepted under the old
    // one must never arrive on the new (#96, PRD §7.6).
    @Test func cancellingClearsWhateverWasWaitingBehindTheSend() async throws {
        let transport = GatedTransport()
        let (outbound, recorder) = Self.outbound(transport)
        outbound.submitInput(Data("a".utf8), generation: 1, canCoalesce: true)
        try await waitUntil { await transport.inputs.count == 1 }
        outbound.submitInput(Data("b".utf8), generation: 1, canCoalesce: true)
        outbound.cancel()
        await transport.release()
        try await waitUntil { recorder.outcomes.contains { if case .sent = $0 { return true } else { return false } } }
        #expect(await transport.inputs == ["a"])
    }

    // A send that succeeds after its connection was replaced is as stale as
    // one that fails: reporting it moved the live connection's idea of the
    // host's grid, and reconciliation then stopped correcting it (#107).
    @Test func aSendThatSucceedsUnderASupersededGenerationIsNotReported() async throws {
        let transport = GatedTransport()
        let live = LiveGeneration()
        let (outbound, recorder) = Self.outbound(transport, liveGeneration: { live.value == $0 })
        outbound.send(.resize(columns: 80, rows: 24), generation: 1)
        try await waitUntil { await transport.resizes.count == 1 }

        // The connection is replaced while the resize is still in flight.
        live.value = 2
        await transport.release()
        await settle()

        #expect(recorder.outcomes.contains { if case .sent = $0 { return true } else { return false } } == false)
    }

    // MARK: - The Ctrl latch

    @Test func theCtrlLatchTurnsTheNextKeyIntoItsControlCode() async throws {
        let transport = GatedTransport()
        let (outbound, _) = Self.outbound(transport)
        outbound.toggleControlLatch()
        outbound.submitInput(Data("c".utf8), generation: 1, canCoalesce: false)
        try await waitUntil { await transport.inputs.count == 1 }
        #expect(await transport.inputs.first == "\u{03}")
    }

    @Test func theCtrlLatchReleasesAfterOneKeystroke() async {
        let transport = GatedTransport()
        let (outbound, _) = Self.outbound(transport)
        outbound.toggleControlLatch()
        outbound.submitInput(Data("c".utf8), generation: 1, canCoalesce: false)
        #expect(outbound.controlLatchActive == false)
    }

    private static func filler(_ bytes: Int) -> Data {
        Data(String(repeating: "x", count: bytes).utf8)
    }

    // MARK: - Wheel reports (#111)

    // An SGR mouse report, the shape Ghostty sends per wheel tick while an
    // agent has mouse tracking on.
    private static func wheelReport(_ tick: Int) -> String {
        "\u{1B}[<64;\(tick % 80 + 1);\(tick % 40 + 1)M"
    }

    private static func wheelData(_ tick: Int) -> Data {
        Data(wheelReport(tick).utf8)
    }

    // Releases sends until nothing more is offered, so a test can read the
    // whole scroll as the frames it actually became.
    private func drain(_ transport: GatedTransport, _ outbound: TerminalOutbound) async throws {
        for _ in 0..<64 {
            await transport.release()
            for _ in 0..<50 { await Task.yield() }
            if outbound.isIdle { return }
        }
        Issue.record("the outbound queue never drained")
    }

    // Scrolling a Claude Code pane put one frame on the wire per wheel tick
    // at sixty a second, which is what queued in front of the heartbeat on
    // cellular. The host reads a longer scroll, not more messages.
    @Test func aScrollOfWheelReportsLeavesAsAHandfulOfFrames() async throws {
        let transport = GatedTransport()
        let (outbound, recorder) = Self.outbound(transport)
        for tick in 0..<200 {
            outbound.submitInput(Self.wheelData(tick), generation: 1, canCoalesce: true)
        }
        try await waitUntil { await transport.inputs.count == 1 }
        try await drain(transport, outbound)

        let frames = await transport.inputs
        #expect(frames.count <= 3)
        let ticks: [String] = (0..<200).map { Self.wheelReport($0) }
        let expected: String = ticks.joined()
        #expect(frames.joined() == expected)
        #expect(recorder.outcomes.contains { if case .backedUp = $0 { true } else { false } } == false)
    }

    // A batch is a batch of wheel reports and nothing else: a keystroke that
    // arrives mid-scroll keeps its place in the stream and its own frame.
    @Test func aKeystrokeAmongWheelReportsKeepsItsOrderAndItsOwnFrame() async throws {
        let transport = GatedTransport()
        let (outbound, _) = Self.outbound(transport)
        outbound.submitInput(Self.wheelData(0), generation: 1, canCoalesce: true)
        try await waitUntil { await transport.inputs.count == 1 }
        for tick in 1...3 {
            outbound.submitInput(Self.wheelData(tick), generation: 1, canCoalesce: true)
        }
        outbound.submitInput(Data("a".utf8), generation: 1, canCoalesce: true)
        for tick in 4...6 {
            outbound.submitInput(Self.wheelData(tick), generation: 1, canCoalesce: true)
        }
        try await drain(transport, outbound)

        let frames = await transport.inputs
        #expect(frames.contains("a"))
        let ticks: [String] = (0...6).map { Self.wheelReport($0) }
        let before: String = ticks[0...3].joined()
        let after: String = ticks[4...6].joined()
        let expected: String = before + "a" + after
        #expect(frames.joined() == expected)
    }

    // The only input Tavi may lose. A queue too deep to be scrolling in time
    // sheds the oldest ticks; every keystroke in it survives, in order, and
    // nothing is refused.
    @Test func aDeepQueueDropsWheelTicksAndNeverAKeystroke() async throws {
        let transport = GatedTransport()
        let (outbound, recorder) = Self.outbound(transport)
        outbound.submitInput(Data("first".utf8), generation: 1, canCoalesce: false)
        try await waitUntil { await transport.inputs.count == 1 }
        for tick in 0..<10 {
            outbound.submitInput(Self.wheelData(tick), generation: 1, canCoalesce: true)
            outbound.submitInput(Data("\(tick)".utf8), generation: 1, canCoalesce: false)
        }
        try await drain(transport, outbound)

        let sent = await transport.inputs.joined()
        #expect(sent.hasPrefix("first"))
        // Every keystroke, in the order it was typed.
        let typed = String(sent.filter(\.isNumber))
        #expect(typed == "0123456789")
        // And fewer wheel reports than the finger made.
        let wheels: Int = sent.components(separatedBy: "\u{1B}[<").count - 1
        #expect(wheels < 10)
        #expect(recorder.outcomes.contains { if case .backedUp = $0 { true } else { false } } == false)
    }
}

// A transport that holds every send open until the test lets it finish, so
// the queue behind it is observable.
private actor GatedTransport: TerminalTransporting {
    private(set) var inputs: [String] = []
    private(set) var resizes: [TerminalClientMessage] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func connect(configuration: TerminalConnectionConfiguration, resume: TerminalResumePoint?) {}

    func receive() async -> TerminalTransportEvent { .disconnected }

    func send(_ message: TerminalClientMessage) async {
        if case let .input(value) = message { inputs.append(value) }
        if case .resize = message { resizes.append(message) }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    func disconnect() {}

    func release() {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume()
    }
}
