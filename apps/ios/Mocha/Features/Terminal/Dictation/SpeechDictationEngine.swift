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
    }

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

        defer {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            shared.withLock { $0.analyzer = nil }
        }

        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true)
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0 else {
                throw DictationFailure.audio("No microphone input.")
            }
            let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
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
