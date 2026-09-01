import Foundation
import Observation

// Voice input for the composer (#56). The safety rule is the whole design:
// dictation only ever edits the composer's draft. This file has no send
// path, no reference to the controller, and no way to reach a pty — the
// transcript becomes editable text and a person taps Send, or nothing
// happens. Homophones in paths and identifiers make anything else a
// liability.

enum DictationPreparation: Equatable, Sendable {
    /// Waiting on the microphone permission prompt.
    case permission
    /// First use on this phone: the on-device speech model for the locale is
    /// being downloaded. Shown honestly instead of looking broken.
    case downloadingModel
}

enum DictationUpdate: Equatable, Sendable {
    case preparing(DictationPreparation)
    case listening
    /// The in-progress segment; replaces the previous volatile text.
    case volatile(String)
    /// A settled segment; appended to what was already committed.
    case finalized(String)
}

enum DictationFailure: Error, Equatable, Sendable {
    case microphoneDenied
    case unsupportedLocale(String)
    case modelUnavailable(String)
    case audio(String)
    case transcription(String)

    /// One plain sentence for the caption under the composer.
    var message: String {
        switch self {
        case .microphoneDenied:
            return "Microphone access is off. Allow it in Settings to dictate."
        case let .unsupportedLocale(identifier):
            return "On-device dictation is not available for \(identifier)."
        case let .modelUnavailable(reason):
            return "The speech model could not be installed. \(reason)"
        case let .audio(reason):
            return "The microphone could not start. \(reason)"
        case let .transcription(reason):
            return "Dictation stopped. \(reason)"
        }
    }

    var isPermissionDenied: Bool {
        if case .microphoneDenied = self { return true }
        return false
    }
}

/// The transcriber behind a seam so the session's state machine is unit
/// tested with a scripted double; the real engine wraps `SpeechAnalyzer`.
protocol DictationEngine: AnyObject, Sendable {
    /// Starts capturing. The stream ends after `stop()` once every final
    /// segment has been delivered, or throws a `DictationFailure`.
    func transcribe() -> AsyncThrowingStream<DictationUpdate, any Error>
    /// Ends capture and lets the engine finalize what it heard.
    func stop()
}

enum DictationState: Equatable {
    case idle
    case preparing(DictationPreparation)
    case listening
    case failed(DictationFailure)

    var isActive: Bool {
        switch self {
        case .preparing, .listening: return true
        case .idle, .failed: return false
        }
    }
}

@MainActor
@Observable
final class DictationSession {
    private(set) var state: DictationState = .idle
    /// The segment still being recognised; shown live, replaced on the next
    /// volatile result, folded into the draft when it finalizes.
    private(set) var volatileText = ""

    private let makeEngine: @MainActor () -> any DictationEngine
    private var engine: (any DictationEngine)?
    private var task: Task<Void, Never>?
    private var anchor = ""
    private var committed = ""
    private var apply: (@MainActor (String) -> Void)?

    init(makeEngine: @escaping @MainActor () -> any DictationEngine) {
        self.makeEngine = makeEngine
    }

    /// The text the composer should show right now: what was there before
    /// the mic was tapped, then every finalized segment, then the live one.
    var draft: String {
        Self.join(Self.join(anchor, committed), volatileText)
    }

    /// Begins dictating *into* `draft`. `apply` receives the composer text
    /// after every change — the only effect this session ever has.
    func start(draft: String, apply: @escaping @MainActor (String) -> Void) {
        guard !state.isActive else { return }
        anchor = draft
        committed = ""
        volatileText = ""
        self.apply = apply
        state = .preparing(.permission)
        let engine = makeEngine()
        self.engine = engine
        task = Task { [weak self] in
            do {
                for try await update in engine.transcribe() {
                    guard let self, !Task.isCancelled else { return }
                    self.handle(update)
                }
                self?.finish(with: nil)
            } catch {
                self?.finish(with: (error as? DictationFailure) ?? .transcription(error.localizedDescription))
            }
        }
    }

    /// Stops listening. Final segments still in flight land in the draft;
    /// the state returns to idle when the engine's stream ends.
    func stop() {
        guard state.isActive else { return }
        engine?.stop()
    }

    /// Abandons dictation without waiting for the engine (leaving the
    /// screen, switching to live mode). Whatever was already committed stays
    /// in the draft; the volatile segment is kept too, since it is text the
    /// person saw.
    func cancel() {
        task?.cancel()
        task = nil
        engine?.stop()
        engine = nil
        if state.isActive {
            fold()
            state = .idle
        }
    }

    /// Clears a failure so the mic button is plain again.
    func dismissFailure() {
        if case .failed = state { state = .idle }
    }

    private func handle(_ update: DictationUpdate) {
        switch update {
        case let .preparing(stage):
            state = .preparing(stage)
        case .listening:
            state = .listening
        case let .volatile(text):
            volatileText = text
            apply?(draft)
        case let .finalized(text):
            committed = Self.join(committed, text)
            volatileText = ""
            apply?(draft)
        }
    }

    private func finish(with failure: DictationFailure?) {
        fold()
        engine = nil
        task = nil
        state = failure.map(DictationState.failed) ?? .idle
    }

    // A segment the engine never finalized is still what the person saw on
    // screen; keep it rather than making words vanish on stop.
    private func fold() {
        guard !volatileText.isEmpty else { return }
        committed = Self.join(committed, volatileText)
        volatileText = ""
        apply?(draft)
    }

    /// Joins two pieces of prose with exactly one space between them, never
    /// inventing whitespace at the ends of empty pieces.
    static func join(_ head: String, _ tail: String) -> String {
        let trimmedTail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTail.isEmpty else { return head }
        guard !head.isEmpty else { return trimmedTail }
        if let last = head.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            return head + trimmedTail
        }
        return head + " " + trimmedTail
    }
}
