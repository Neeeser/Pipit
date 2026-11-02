import AVFoundation
import FluidAudio
import Foundation
import PipitAudio
import PipitCore
import Speech

/// One phrase of live text: what Parakeet heard in a few seconds of audio cut
/// at a pause, with word times relative to the start of that audio.
public struct LivePhraseText: Sendable {
    public var text: String
    public var words: [CtcForcedAlignment.AlignedWord]
}

extension LocalModelManager {
    /// Parakeet over one short phrase of 16 kHz mono samples.
    ///
    /// Uses the same loaded model as the post-call pass, so the live text
    /// costs no second copy of it in memory, and runs on the actor, so a
    /// phrase waits behind any other heavy job that holds the model.
    public func transcribeLivePhrase(_ samples: [Float]) async throws -> LivePhraseText {
        let manager = try await loadedParakeet()
        // Parakeet refuses anything under 0.3 s. A phrase that short is padded
        // with silence rather than dropped, since it is often a whole "yes".
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: VadManager.sampleRate)
        let input = samples.count >= minimum ? samples : samples + Array(repeating: 0, count: minimum - samples.count)
        var decoderState = TdtDecoderState.make()
        let result = try await manager.transcribe(input, decoderState: &decoderState)
        let words = buildWordTimings(from: result.tokenTimings ?? []).map {
            CtcForcedAlignment.AlignedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
        return LivePhraseText(text: result.text, words: words)
    }

    /// A voice detector that keeps its own running state, for one track
    /// scored a window at a time as it is recorded.
    public func liveVoiceActivity() async throws -> LiveVoiceActivity {
        LiveVoiceActivity(manager: try await loadedVoiceActivity())
    }
}

/// Silero over one live track. One per track: the model state carries from
/// window to window, and two tracks through one state would blur together.
public actor LiveVoiceActivity {
    /// Samples per window at 16 kHz, 256 ms.
    public static let windowSamples = VadManager.chunkSize
    private let manager: VadManager
    private var state: VadStreamState?

    init(manager: VadManager) {
        self.manager = manager
    }

    /// The speech probability of one window of `windowSamples` samples.
    public func probability(_ window: [Float]) async throws -> Float {
        let current: VadStreamState
        if let state {
            current = state
        } else {
            current = await manager.makeStreamState()
        }
        let result = try await manager.processStreamingChunk(window, state: current)
        state = result.state
        return result.probability
    }
}

/// A piece of live text from an engine that revises itself as it hears more.
/// Volatile text is a guess the engine will replace; final text stays.
public struct LiveStreamText: Sendable {
    public var text: String
    public var isFinal: Bool
    /// Seconds into the track that this text covers.
    public var start: Double
    public var end: Double
}

#if compiler(>=6.2)
    /// Apple's SpeechAnalyzer fed one track as it is recorded.
    ///
    /// One per track, like the voice detector: the analyzer keeps its own
    /// running state, and two tracks through one would interleave.
    @available(macOS 26.0, *)
    public actor AppleLiveTranscriber {
        private let analyzer: SpeechAnalyzer
        private let input: AsyncStream<AnalyzerInput>.Continuation
        private let format: AVAudioFormat
        private let sourceFormat: AVAudioFormat
        private let converter: AVAudioConverter?
        /// Volatile and final text in the order the engine produced it.
        public nonisolated let results: AsyncThrowingStream<LiveStreamText, Error>

        public static func start() async throws -> AppleLiveTranscriber {
            let transcriber = try await AppleSpeechAnalyzerRunner.preparedTranscriber(
                reportingOptions: [.volatileResults]
            )
            guard
                let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
                let source = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
                )
            else { throw AppleSpeechError.localeUnsupported }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
            let (results, publish) = AsyncThrowingStream<LiveStreamText, Error>.makeStream()
            Task {
                do {
                    for try await result in transcriber.results {
                        publish.yield(
                            LiveStreamText(
                                text: String(result.text.characters), isFinal: result.isFinal,
                                start: result.range.start.seconds,
                                end: result.range.end.seconds
                            ))
                    }
                    publish.finish()
                } catch {
                    publish.finish(throwing: error)
                }
            }
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream)
            return AppleLiveTranscriber(
                analyzer: analyzer, input: input, format: format, sourceFormat: source, results: results
            )
        }

        private init(
            analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation,
            format: AVAudioFormat, sourceFormat: AVAudioFormat,
            results: AsyncThrowingStream<LiveStreamText, Error>
        ) {
            self.analyzer = analyzer
            self.input = input
            self.format = format
            self.sourceFormat = sourceFormat
            self.converter = format == sourceFormat ? nil : AVAudioConverter(from: sourceFormat, to: format)
            self.results = results
        }

        /// Hands the analyzer the next stretch of 16 kHz mono samples.
        public func feed(_ samples: [Float]) {
            guard !samples.isEmpty,
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)
                ), let channel = buffer.floatChannelData?[0]
            else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
            }
            guard let converter else {
                input.yield(AnalyzerInput(buffer: buffer))
                return
            }
            let ratio = format.sampleRate / sourceFormat.sampleRate
            guard
                let converted = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(samples.count) * ratio) + 64
                )
            else { return }
            // The converter keeps its own state between calls, so a resampled
            // stream fed in pieces comes out continuous.
            let source = LockedBox<AVAudioPCMBuffer?>(buffer)
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, status in
                source.withLock { pending in
                    guard let next = pending else {
                        status.pointee = .noDataNow
                        return nil
                    }
                    pending = nil
                    status.pointee = .haveData
                    return next
                }
            }
            if conversionError == nil, converted.frameLength > 0 {
                input.yield(AnalyzerInput(buffer: converted))
            }
        }

        /// Ends the input and waits for the analyzer to finalise what it has.
        public func finish() async throws {
            input.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
    }
#endif
