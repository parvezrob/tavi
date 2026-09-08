import Foundation
import Observation
import os

// The terminal's outbound path: one send in flight at a time, whatever
// arrives meanwhile queued behind it, typing coalesced so a fast typist
// costs one frame. The controller owns the connection and decides what a
// failure means; this owns the order bytes leave in.
@MainActor
@Observable
final class TerminalOutbound {
    typealias GenerationCheck = @MainActor (Int) -> Bool
    typealias OutcomeConsumer = @MainActor (Outcome) -> Void

    // What the controller has to act on; the rest is bookkeeping.
    enum Outcome {
        case sent(TerminalClientMessage)
        // The error is nil when the transport failed with something this
        // client has no name for.
        case failed(TerminalTransportError?, inputWasSubmitted: Bool)
        // Nothing queued and nothing in flight.
        case drained
        // The queue is full: keys are refused out loud, never dropped.
        case backedUp
    }

    private static let logger = Logger(subsystem: "com.farfield.tavi", category: "terminal.connection")
    private static let maximumCoalescedInputBytes = 4 * 1_024
    private static let maximumPendingInputBytes = 64 * 1_024
    // Past this depth the outbound path is not keeping up with the pointer.
    // Eight chunks is a few frames of scrolling: long enough to ride out one
    // slow send, short enough that catching up costs a shorter scroll.
    private static let maximumPendingChunks = 8
    // The four wheel directions. A tick carrying a modifier is a different
    // button and stays undroppable: losing one is not worth the risk of
    // guessing wrong about what the application asked for.
    private static let wheelButtons = 64...67

    // One-shot Ctrl modifier for the quick-key row.
    private(set) var controlLatchActive = false

    private let client: any TerminalTransporting
    private let inputDelivery: TerminalInputDelivery
    private var isCurrentConnection: GenerationCheck?
    private var outcomeConsumer: OutcomeConsumer?
    private var task: Task<Void, Never>?
    private var taskID: UUID?
    // The priority send, owned like every other task the connection starts:
    // it is in no drain order, so nothing else would ever release it and a
    // stalled one outlived the connection that asked for it (#111).
    private var priorityTask: Task<Void, Never>?
    private var pendingInputChunks: [PendingTerminalInput] = []
    private var pendingInputByteCount = 0
    // The generation the queue was accepted under; a connection change
    // clears the queue, so a drain always sends under this one.
    private var generation = 0

    init(client: any TerminalTransporting) {
        self.client = client
        inputDelivery = TerminalInputDelivery(sender: client)
    }

    func installGenerationCheck(_ check: @escaping GenerationCheck) {
        isCurrentConnection = check
    }

    func installOutcomeConsumer(_ consumer: @escaping OutcomeConsumer) {
        outcomeConsumer = consumer
    }

    // Nothing is in flight, so a deferred resize may go now.
    var isIdle: Bool { task == nil }

    func toggleControlLatch() {
        controlLatchActive.toggle()
    }

    func submitInput(_ data: Data, generation: Int, canCoalesce: Bool) {
        self.generation = generation
        var data = data
        if controlLatchActive {
            // One-shot Ctrl modifier from the quick row: the next single
            // keystroke becomes its control code; anything unmappable
            // passes through and still releases the latch.
            controlLatchActive = false
            if let controlCode = TerminalControlKeyMapper.controlCode(for: data) {
                data = controlCode
            }
        }
        let isWheelReports = Self.isWheelReports(data)
        // One line per batch rather than one per wheel tick: at sixty
        // reports a second the log was itself part of the cost (#111).
        if data.first == 0x1B, !isWheelReports {
            Self.logger.info("terminal-originated control sequence, \(data.count) bytes")
        }

        guard task == nil, pendingInputChunks.isEmpty else {
            enqueue(data, canCoalesce: canCoalesce, isWheelReports: isWheelReports)
            return
        }
        sendInput(data, isWheelReports: isWheelReports)
    }

    // Whether this buffer is wheel ticks and nothing else, which is the
    // only thing that may be dropped. Judging it by its first and last byte
    // was wrong twice: a batch with typed text glued into the middle looked
    // droppable and would have taken keystrokes with it, and every SGR
    // button press and release matched, so dropping a press while keeping
    // its release left the application mid-drag. Every sequence in the
    // buffer has to be parsed, and every one of them has to be a wheel tick
    // (#111).
    private static func isWheelReports(_ data: Data) -> Bool {
        var index = data.startIndex
        var found = 0
        while index < data.endIndex {
            guard let end = wheelReportEnd(of: data, from: index) else { return false }
            index = end
            found += 1
        }
        return found > 0
    }

    // Just past one complete `ESC [ < button ; column ; row M|m` whose
    // button is a wheel tick, or nil for anything else: another button, a
    // sequence cut short by the end of the buffer, or ordinary typed bytes.
    private static func wheelReportEnd(of data: Data, from start: Data.Index) -> Data.Index? {
        var index = start
        func take(_ byte: UInt8) -> Bool {
            guard index < data.endIndex, data[index] == byte else { return false }
            index = data.index(after: index)
            return true
        }
        func takeParameter() -> Int? {
            var value = 0
            var digits = 0
            while index < data.endIndex, let digit = Self.digit(data[index]) {
                // Longer than any coordinate a terminal reports, so it is
                // not one.
                guard digits < 5 else { return nil }
                value = value * 10 + digit
                digits += 1
                index = data.index(after: index)
            }
            return digits > 0 ? value : nil
        }
        guard take(0x1B), take(UInt8(ascii: "[")), take(UInt8(ascii: "<")),
              let button = takeParameter(), Self.wheelButtons.contains(button),
              take(UInt8(ascii: ";")), takeParameter() != nil,
              take(UInt8(ascii: ";")), takeParameter() != nil,
              take(UInt8(ascii: "M")) || take(UInt8(ascii: "m")) else { return nil }
        return index
    }

    private static func digit(_ byte: UInt8) -> Int? {
        guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
        return Int(byte - UInt8(ascii: "0"))
    }

    @discardableResult
    func send(
        _ message: TerminalClientMessage,
        generation: Int,
        inputWasSubmitted: Bool = false
    ) -> Task<Void, Never> {
        self.generation = generation
        let previousTask = task
        let taskID = UUID()
        self.taskID = taskID
        let task = Task { [weak self] in
            if let previousTask {
                await previousTask.value
            }
            guard let self, isCurrentConnection?(generation) == true else { return }
            defer { finish(taskID) }
            await deliver(message, generation: generation, inputWasSubmitted: inputWasSubmitted)
        }
        self.task = task
        return task
    }

    // The heartbeat's ping does not queue. A pane with mouse tracking on
    // fills the outbound path with wheel reports, and a ping behind them
    // made the send bound measure that drain rather than the ping — the
    // socket was answering the whole time (#111). It joins no drain order,
    // so no input can be reordered by it.
    @discardableResult
    func sendAhead(_ message: TerminalClientMessage, generation: Int) -> Task<Void, Never> {
        priorityTask?.cancel()
        let task = Task { [weak self] in
            guard let self, isCurrentConnection?(generation) == true else { return }
            await deliver(message, generation: generation, inputWasSubmitted: false)
        }
        priorityTask = task
        return task
    }

    // One send and the three ways it ends, shared by the queued path and the
    // priority one.
    private func deliver(
        _ message: TerminalClientMessage,
        generation: Int,
        inputWasSubmitted: Bool
    ) async {
        do {
            if case let .input(data) = message {
                try await inputDelivery.submitOnce(Data(data.utf8))
            } else {
                try await client.send(message)
            }
            // Success is fenced like failure: a resize completing after its
            // connection was replaced would move the live one's idea of the
            // host's grid (#107).
            guard isCurrentConnection?(generation) == true else { return }
            outcomeConsumer?(.sent(message))
        } catch let error as TerminalTransportError {
            guard isCurrentConnection?(generation) == true else { return }
            outcomeConsumer?(.failed(error, inputWasSubmitted: inputWasSubmitted))
        } catch {
            guard isCurrentConnection?(generation) == true else { return }
            outcomeConsumer?(.failed(nil, inputWasSubmitted: inputWasSubmitted))
        }
    }

    func cancel() {
        task?.cancel()
        priorityTask?.cancel()
        task = nil
        priorityTask = nil
        taskID = nil
        pendingInputChunks.removeAll(keepingCapacity: false)
        pendingInputByteCount = 0
    }

    private func enqueue(_ data: Data, canCoalesce: Bool, isWheelReports: Bool) {
        // Wheel reports never earn a refusal: a queue too full for them
        // sheds the oldest of them below instead.
        guard isWheelReports || pendingInputByteCount <= Self.maximumPendingInputBytes - data.count else {
            outcomeConsumer?(.backedUp)
            return
        }

        // Wheel reports merge only with wheel reports, so a batch stays one
        // droppable unit and no keystroke is ever inside one.
        if canCoalesce,
           let lastIndex = pendingInputChunks.indices.last,
           pendingInputChunks[lastIndex].canCoalesce,
           pendingInputChunks[lastIndex].isWheelReports == isWheelReports,
           pendingInputChunks[lastIndex].data.count <= Self.maximumCoalescedInputBytes - data.count {
            pendingInputChunks[lastIndex].data.append(data)
        } else {
            pendingInputChunks.append(
                PendingTerminalInput(data: data, canCoalesce: canCoalesce, isWheelReports: isWheelReports)
            )
        }
        pendingInputByteCount += data.count
        dropOldestWheelReports()
    }

    // The only input Tavi may lose, and only when the queue is already too
    // deep to be scrolling in time: a dropped tick is a shorter scroll, a
    // dropped keystroke is a lie about what was typed. Whole chunks go, so
    // nothing left behind is reordered or cut mid-sequence.
    private func dropOldestWheelReports() {
        while pendingInputChunks.count > Self.maximumPendingChunks,
              let index = pendingInputChunks.firstIndex(where: \.isWheelReports) {
            pendingInputByteCount -= pendingInputChunks[index].data.count
            pendingInputChunks.remove(at: index)
        }
    }

    private func sendInput(_ data: Data, isWheelReports: Bool) {
        if isWheelReports {
            Self.logger.info("wheel reports batched, \(data.count) bytes")
        }
        let value = String(decoding: data, as: UTF8.self)
        send(.input(value), generation: generation, inputWasSubmitted: true)
    }

    private func finish(_ taskID: UUID) {
        guard self.taskID == taskID else { return }
        task = nil
        self.taskID = nil
        guard pendingInputChunks.isEmpty else {
            let pending = pendingInputChunks.removeFirst()
            pendingInputByteCount -= pending.data.count
            sendInput(pending.data, isWheelReports: pending.isWheelReports)
            return
        }
        outcomeConsumer?(.drained)
    }
}

private struct PendingTerminalInput {
    var data: Data
    let canCoalesce: Bool
    let isWheelReports: Bool
}
