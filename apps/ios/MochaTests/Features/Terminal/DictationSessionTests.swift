import Foundation
import Testing
@testable import Mocha

// The composer's voice state machine (#56), driven by a scripted engine.
// The property under test throughout: dictation only ever rewrites the
// draft, and every path ends with the words the person saw still on screen.
@MainActor
struct DictationSessionTests {
    @Test
    func volatileTextReplacesAndFinalTextAccumulatesIntoTheDraft() async {
        let engine = ScriptedEngine()
        let session = DictationSession(makeEngine: { engine })
        var drafts: [String] = []

        session.start(draft: "") { drafts.append($0) }
        await engine.emit(.listening)
        #expect(session.state == .listening)
        await engine.emit(.volatile("open the"))
        await engine.emit(.volatile("open the readme"))
        await engine.emit(.finalized("open the readme"))
        await engine.emit(.volatile("and fix"))
        await engine.emit(.finalized("and fix the typo"))
        session.stop()
        await engine.finish()
        await session.settled()

        #expect(drafts == ["open the", "open the readme", "open the readme", "open the readme and fix", "open the readme and fix the typo"])
        #expect(session.draft == "open the readme and fix the typo")
        #expect(session.state == .idle)
        #expect(engine.stopCalls == 1)
    }

    @Test
    func dictationAppendsToWhatWasAlreadyTyped() async {
        let engine = ScriptedEngine()
        let session = DictationSession(makeEngine: { engine })
        var latest = "run the tests"

        session.start(draft: latest) { latest = $0 }
        await engine.emit(.listening)
        await engine.emit(.finalized("then commit"))
        session.stop()
        await engine.finish()
        await session.settled()

        #expect(latest == "run the tests then commit")
    }

    @Test
    func stoppingKeepsAnUnfinalizedSegmentTheUserSaw() async {
        let engine = ScriptedEngine()
        let session = DictationSession(makeEngine: { engine })
        var latest = ""

        session.start(draft: "") { latest = $0 }
        await engine.emit(.listening)
        await engine.emit(.volatile("rename the branch"))
        session.stop()
        await engine.finish()
        await session.settled()

        #expect(latest == "rename the branch")
        #expect(session.volatileText.isEmpty)
        #expect(session.state == .idle)
    }

    @Test
    func cancelAbandonsTheEngineWithoutWaiting() async {
        let engine = ScriptedEngine()
        let session = DictationSession(makeEngine: { engine })
        var latest = ""

        session.start(draft: "") { latest = $0 }
        await engine.emit(.listening)
        await engine.emit(.volatile("half a"))
        session.cancel()
        await Task.yield()

        #expect(session.state == .idle)
        #expect(latest == "half a")
        #expect(engine.stopCalls == 1)
    }

    @Test
    func deniedMicrophoneBecomesAFailureWithASettingsHint() async {
        let engine = ScriptedEngine()
        let session = DictationSession(makeEngine: { engine })
        var applied = 0

        session.start(draft: "") { _ in applied += 1 }
        await engine.emit(.preparing(.permission))
        #expect(session.state == .preparing(.permission))
        await engine.fail(.microphoneDenied)
        await session.settled()

        #expect(session.state == .failed(.microphoneDenied))
        #expect(applied == 0)
        if case let .failed(failure) = session.state {
            #expect(failure.isPermissionDenied)
        }
        session.dismissFailure()
        #expect(session.state == .idle)
    }

    @Test
    func modelDownloadIsReportedAsPreparing() async {
        let engine = ScriptedEngine()
        let session = DictationSession(makeEngine: { engine })

        session.start(draft: "") { _ in }
        await engine.emit(.preparing(.downloadingModel))
        #expect(session.state == .preparing(.downloadingModel))
        session.cancel()
    }

    @Test
    func startIsIgnoredWhileActive() async {
        let engine = ScriptedEngine()
        var made = 0
        let session = DictationSession(makeEngine: { made += 1; return engine })

        session.start(draft: "") { _ in }
        session.start(draft: "") { _ in }
        #expect(made == 1)
        session.cancel()
    }

    @Test
    func joinNeverDoublesOrInventsSpaces() {
        #expect(DictationSession.join("", "hello") == "hello")
        #expect(DictationSession.join("hello", "") == "hello")
        #expect(DictationSession.join("hello", "   ") == "hello")
        #expect(DictationSession.join("hello", "world") == "hello world")
        #expect(DictationSession.join("hello ", "world") == "hello world")
        #expect(DictationSession.join("hello\n", " world ") == "hello\nworld")
    }
}

// A scripted engine: the test pushes updates, the session reacts. The
// stream exists from construction so an update pushed before the session's
// consumer task has started is buffered, not dropped. `emit` then waits
// until the session has visibly taken the update.
@MainActor
private final class ScriptedEngine: DictationEngine, @unchecked Sendable {
    private let stream: AsyncThrowingStream<DictationUpdate, any Error>
    private let continuation: AsyncThrowingStream<DictationUpdate, any Error>.Continuation
    private(set) var stopCalls = 0
    private(set) var delivered = 0
    weak var session: DictationSession?

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    nonisolated func transcribe() -> AsyncThrowingStream<DictationUpdate, any Error> {
        stream
    }

    nonisolated func stop() {
        Task { @MainActor in self.stopCalls += 1 }
    }

    func emit(_ update: DictationUpdate) async {
        continuation.yield(update)
        await settle()
    }

    func finish() async {
        continuation.finish()
        await settle()
    }

    func fail(_ failure: DictationFailure) async {
        continuation.finish(throwing: failure)
        await settle()
    }

    // Lets the session's consumer task run through everything buffered.
    private func settle() async {
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

private extension DictationSession {
    // The consumer task finishes a few hops after the stream ends.
    func settled() async {
        for _ in 0..<100 where state.isActive {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}
