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

    private static func outbound(_ transport: GatedTransport) -> (TerminalOutbound, Recorder) {
        let outbound = TerminalOutbound(client: transport)
        let recorder = Recorder()
        outbound.installGenerationCheck { _ in true }
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
}

// A transport that holds every send open until the test lets it finish, so
// the queue behind it is observable.
private actor GatedTransport: TerminalTransporting {
    private(set) var inputs: [String] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func connect(configuration: TerminalConnectionConfiguration, resume: TerminalResumePoint?) {}

    func receive() async -> TerminalTransportEvent { .disconnected }

    func send(_ message: TerminalClientMessage) async {
        if case let .input(value) = message { inputs.append(value) }
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
