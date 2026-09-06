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

    // One-shot Ctrl modifier for the quick-key row.
    private(set) var controlLatchActive = false

    private let client: any TerminalTransporting
    private let inputDelivery: TerminalInputDelivery
    private var isCurrentConnection: GenerationCheck?
    private var outcomeConsumer: OutcomeConsumer?
    private var task: Task<Void, Never>?
    private var taskID: UUID?
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
        if data.first == 0x1B {
            Self.logger.info("terminal-originated control sequence, \(data.count) bytes")
        }

        guard task == nil, pendingInputChunks.isEmpty else {
            enqueue(data, canCoalesce: canCoalesce)
            return
        }
        sendInput(data)
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
            do {
                if case let .input(data) = message {
                    try await inputDelivery.submitOnce(Data(data.utf8))
                } else {
                    try await client.send(message)
                }
                // Success is fenced like failure: a resize completing after
                // its connection was replaced would move the live one's idea
                // of the host's grid (#107).
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
        self.task = task
        return task
    }

    func cancel() {
        task?.cancel()
        task = nil
        taskID = nil
        pendingInputChunks.removeAll(keepingCapacity: false)
        pendingInputByteCount = 0
    }

    private func enqueue(_ data: Data, canCoalesce: Bool) {
        guard pendingInputByteCount <= Self.maximumPendingInputBytes - data.count else {
            outcomeConsumer?(.backedUp)
            return
        }

        if canCoalesce,
           let lastIndex = pendingInputChunks.indices.last,
           pendingInputChunks[lastIndex].canCoalesce,
           pendingInputChunks[lastIndex].data.count <= Self.maximumCoalescedInputBytes - data.count {
            pendingInputChunks[lastIndex].data.append(data)
        } else {
            pendingInputChunks.append(PendingTerminalInput(data: data, canCoalesce: canCoalesce))
        }
        pendingInputByteCount += data.count
    }

    private func sendInput(_ data: Data) {
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
            sendInput(pending.data)
            return
        }
        outcomeConsumer?(.drained)
    }
}

private struct PendingTerminalInput {
    var data: Data
    let canCoalesce: Bool
}
