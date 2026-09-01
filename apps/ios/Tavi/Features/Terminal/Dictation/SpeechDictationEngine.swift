import AVFoundation
import Foundation
import os
import Speech

// The real transcriber (#56): iOS 26 `SpeechAnalyzer` + `SpeechTranscriber`,
// on device, not the legacy `SFSpeechRecognizer`. Audio comes from
// `AVAudioEngine`'s input tap, converted to the analyzer's preferred format.
// The first use per locale downloads a model; that state is reported rather
// than hidden behind a spinner that looks hung.
final class SpeechDictationEngine: DictationEngine, @unchecked Sendable {
    private struct Shared {
        var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
        var analyzer: SpeechAnalyzer?
        var stopped = false
        var interruption: String?
        var lastLevelAt: TimeInterval = 0
    }

    private static let levelInterval: TimeInterval = 1.0 / 12

    private let shared = OSAllocatedUnfairLock(initialState: Shared())

    func transcribe() -> AsyncThrowingStream<DictationUpdate, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try await run(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [self] _ in
                stop()
                task.cancel()
            }
        }
    }

    func stop() {
        let (alreadyStopped, input, analyzer) = shared.withLock { state in
            let result = (state.stopped, state.inputContinuation, state.analyzer)
            state.stopped = true
            state.inputContinuation = nil
            return result
        }
        guard !alreadyStopped else { return }
        input?.finish()
        if let analyzer {
            Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        }
    }

    private func run(_ continuation: AsyncThrowingStream<DictationUpdate, any Error>.Continuation) async throws {
        continuation.yield(.preparing(.permission))
        guard await AVAudioApplication.requestRecordPermission() else {
            throw DictationFailure.microphoneDenied
        }

        let requested = Locale.current
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw DictationFailure.unsupportedLocale(requested.identifier)
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                continuation.yield(.preparing(.downloadingModel))
                try await request.downloadAndInstall()
            }
        } catch {
            throw DictationFailure.modelUnavailable(error.localizedDescription)
        }
        if isStopped { return }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationFailure.audio("No compatible audio format.")
        }

        let audioSession = AVAudioSession.sharedInstance()
        let audioEngine = AVAudioEngine()
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        shared.withLock { state in
            state.inputContinuation = inputBuilder
            state.analyzer = analyzer
        }

        // Audio can be taken away at any moment — a call, Siri, an alarm
        // (`AVAudioSession.interruptionNotification`) — or the graph can be
        // torn down under us when the route changes, e.g. AirPods connect
        // mid-sentence (`AVAudioEngineConfigurationChange`: the engine stops
        // and the input format may differ). Either way the honest move for
        // dictation is to end it with the words so far and say why, not to
        // sit in "Listening" with a dead tap or resume into a different mic.
        let center = NotificationCenter.default
        let interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: nil
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawType) == .began else { return }
            self?.interrupt(reason: "another app took the microphone")
        }
        let configurationObserver = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] _ in
            self?.interrupt(reason: "the audio route changed")
        }

        defer {
            center.removeObserver(interruptionObserver)
            center.removeObserver(configurationObserver)
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            shared.withLock { $0.analyzer = nil }
        }

        do {
            // Speech, not measurement: `.spokenAudio` keeps the system's voice
            // processing on (Apple's SpeechAnalyzer sample uses the same
            // pair), `.duckOthers` lowers music instead of fighting it, and
            // Bluetooth HFP lets AirPods be the microphone.
            try audioSession.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.duckOthers, .allowBluetoothHFP]
            )
            try audioSession.setActive(true)
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw DictationFailure.audio("No microphone input.")
            }
            let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
            converter?.primeMethod = .none
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, when in
                guard let self else { return }
                self.reportLevel(of: buffer, at: when, to: continuation)
                guard let converted = Self.convert(buffer, using: converter, to: analyzerFormat) else { return }
                inputBuilder.yield(AnalyzerInput(buffer: converted))
            }
            audioEngine.prepare()
            try audioEngine.start()
        } catch let failure as DictationFailure {
            throw failure
        } catch {
            throw DictationFailure.audio(error.localizedDescription)
        }

        try await analyzer.start(inputSequence: inputSequence)
        continuation.yield(.listening)

        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                continuation.yield(result.isFinal ? .finalized(text) : .volatile(text))
            }
        } catch {
            if isStopped { return }
            throw DictationFailure.transcription(error.localizedDescription)
        }
        if let reason = shared.withLock({ $0.interruption }) {
            throw DictationFailure.interrupted(reason)
        }
    }

    private func interrupt(reason: String) {
        let alreadyStopped = shared.withLock { state -> Bool in
            let was = state.stopped
            if !was { state.interruption = reason }
            return was
        }
        guard !alreadyStopped else { return }
        stop()
    }

    // RMS of the first channel, mapped onto a perceptual-ish 0…1 range and
    // throttled to ~12 Hz so the UI shows a meter, not a firehose.
    private func reportLevel(
        of buffer: AVAudioPCMBuffer,
        at when: AVAudioTime,
        to continuation: AsyncThrowingStream<DictationUpdate, any Error>.Continuation
    ) {
        let now = Date.timeIntervalSinceReferenceDate
        let due = shared.withLock { state -> Bool in
            guard now - state.lastLevelAt >= Self.levelInterval else { return false }
            state.lastLevelAt = now
            return true
        }
        guard due, let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        // -50 dBFS (room tone) → 0, -10 dBFS (loud speech) → 1.
        let decibels = 20 * log10(max(rms, 1e-7))
        let level = min(1, max(0, (decibels + 50) / 40))
        continuation.yield(.level(level))
    }

    private var isStopped: Bool {
        shared.withLock { $0.stopped }
    }

    // The analyzer wants its own sample rate/layout; the mic gives whatever
    // the route offers. Frame counts scale with the rate ratio.
    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter?,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer.format == format ? buffer : nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        // The converter pulls synchronously on this thread; the input block
        // never outlives the call, so the captures are safe despite the
        // `@Sendable` annotation on the block type.
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let input = buffer
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
