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
                reportingOptions: [.volatileResults, .fastResults]
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

/// Parakeet run the way the live transcript runs it: the voice detector cuts
/// the track into phrases at pauses and each phrase is transcribed on its own.
///
/// A benchmark candidate, reachable through `pipit-eval bench --live-phrases`.
/// It answers whether the live text could be the meeting's final transcript:
/// the rest of the pipeline is unchanged, so its score against the reference
/// transcripts compares directly with the whole-track pass.
public struct ParakeetPhraseTranscriptionBackend: TranscriptionBackend {
    private let models: LocalModelManager
    private let tuning: LiveSpeechSegmenter.Tuning

    public init(models: LocalModelManager, tuning: LiveSpeechSegmenter.Tuning = .default) {
        self.models = models
        self.tuning = tuning
    }

    public var identifier: String { LocalSpeechStack.parakeetBackendIdentifier + "-phrases" }
    public var isLocal: Bool { true }
    public var limits: BackendAudioLimits { .none }
    public var timing: TranscriptTiming { .words }

    public func transcribe(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionOutput {
        let samples = try MonoAudioDecoder.loadMono16k(audio)
        let detector = try await models.liveVoiceActivity()
        let window = LiveVoiceActivity.windowSamples
        let windowSeconds = Double(window) / 16_000
        var segmenter = LiveSpeechSegmenter(tuning: tuning)
        var phrases: [LiveSpeechSegmenter.Phrase] = []
        var offset = 0
        while offset + window <= samples.count {
            let probability = try await detector.probability(Array(samples[offset..<offset + window]))
            if let phrase = segmenter.push(probability) { phrases.append(phrase) }
            offset += window
        }
        if let phrase = segmenter.finish() { phrases.append(phrase) }

        var words: [CtcForcedAlignment.AlignedWord] = []
        var texts: [String] = []
        for (index, phrase) in phrases.enumerated() {
            let start = min(samples.count, phrase.start * window)
            let end = min(samples.count, phrase.end * window)
            guard end > start else { continue }
            let text = try await models.transcribeLivePhrase(Array(samples[start..<end]))
            let base = Double(phrase.start) * windowSeconds
            words += text.words.map {
                CtcForcedAlignment.AlignedWord(text: $0.text, start: $0.start + base, end: $0.end + base)
            }
            if !text.text.isEmpty { texts.append(text.text) }
            progress(Double(index + 1) / Double(max(1, phrases.count)))
        }
        progress(1)
        return TranscriptionOutput(
            segments: CtcForcedAlignment.segments(
                from: words,
                pauseSeconds: LocalAlignmentTuning.segmentPauseSeconds,
                maximumSeconds: LocalAlignmentTuning.segmentMaximumSeconds
            ),
            text: texts.joined(separator: " "),
            durationSeconds: Double(samples.count) / 16_000
        )
    }
}

/// Parakeet through FluidAudio's sliding-window streamer: 11-second windows
/// with 2 seconds of context either side, the layout its whole-file pass
/// uses, fed as if the track were being recorded.
///
/// A benchmark candidate, reachable through `pipit-eval bench --live-sliding`.
/// It answers whether a live pass can produce the same transcript as the
/// after-call pass, rather than a faster but lossier one.
public struct ParakeetSlidingTranscriptionBackend: TranscriptionBackend {
    private let models: LocalModelManager

    public init(models: LocalModelManager) {
        self.models = models
    }

    public var identifier: String { LocalSpeechStack.parakeetBackendIdentifier + "-sliding" }
    public var isLocal: Bool { true }
    public var limits: BackendAudioLimits { .none }
    public var timing: TranscriptTiming { .words }

    public func transcribe(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionOutput {
        let samples = try MonoAudioDecoder.loadMono16k(audio)
        let words = try await models.transcribeSlidingWindow(samples)
        progress(1)
        return TranscriptionOutput(
            segments: CtcForcedAlignment.segments(
                from: words,
                pauseSeconds: LocalAlignmentTuning.segmentPauseSeconds,
                maximumSeconds: LocalAlignmentTuning.segmentMaximumSeconds
            ),
            text: words.map(\.text).joined(separator: " "),
            durationSeconds: Double(samples.count) / 16_000
        )
    }
}

extension LocalModelManager {
    /// One track through a fresh sliding-window streamer, one second of audio
    /// at a time, with the token revisions applied the way a live view would.
    func transcribeSlidingWindow(_ samples: [Float]) async throws -> [CtcForcedAlignment.AlignedWord] {
        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = false }
        let models = try await AsrModels.load(
            from: locations.parakeetDirectory, version: .v3, encoderPrecision: .int8
        )
        let streamer = SlidingWindowAsrManager(config: .default)
        try await streamer.loadModels(models)
        let updates = await streamer.tokenUpdates
        let collector = Task {
            var tokens: [TokenTiming] = []
            for try await update in updates {
                tokens = Array(tokens.prefix(update.revision.retainedTokenCount)) + update.tokens
            }
            return tokens
        }
        try await streamer.startStreaming(source: .system)
        var offset = 0
        while offset < samples.count {
            let count = min(16_000, samples.count - offset)
            guard let buffer = Self.slidingBuffer(samples[offset..<offset + count]) else { break }
            await streamer.streamAudio(buffer)
            offset += count
        }
        _ = try await streamer.finish()
        let tokens = try await collector.value
        return buildWordTimings(from: tokens).map {
            CtcForcedAlignment.AlignedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
    }

    /// One 16 kHz mono buffer that owns its format, so it can be handed to
    /// the streamer's actor without sharing anything with the next one.
    static func slidingBuffer(_ samples: ArraySlice<Float>) -> sending AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        return buffer
    }
}

/// Parakeet Unified 0.6B through FluidAudio's streaming manager: a model
/// trained for both whole-file and streaming use, whose encoder sees about
/// 5.6 seconds behind and 1 second ahead of each 1-second chunk, so text is
/// final about 2 seconds after it is spoken.
///
/// A benchmark candidate, reachable through `pipit-eval bench --live-unified`.
/// It answers whether one model can be both the live transcript and the saved
/// one. English only; the model arrives on first use, the way LS-EEND's does.
public struct ParakeetUnifiedTranscriptionBackend: TranscriptionBackend {
    private let models: LocalModelManager

    public init(models: LocalModelManager) {
        self.models = models
    }

    public var identifier: String { "parakeet-unified-en-streaming-0.18.2" }
    public var isLocal: Bool { true }
    public var limits: BackendAudioLimits { .none }
    public var timing: TranscriptTiming { .words }

    public func transcribe(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionOutput {
        let samples = try MonoAudioDecoder.loadMono16k(audio)
        let words = try await models.transcribeUnifiedStreaming(samples)
        progress(1)
        return TranscriptionOutput(
            segments: CtcForcedAlignment.segments(
                from: words,
                pauseSeconds: LocalAlignmentTuning.segmentPauseSeconds,
                maximumSeconds: LocalAlignmentTuning.segmentMaximumSeconds
            ),
            text: words.map(\.text).joined(separator: " "),
            durationSeconds: Double(samples.count) / 16_000
        )
    }
}

extension LocalModelManager {
    /// One track through a fresh Unified streamer, one second at a time,
    /// draining word timings after every chunk the way a live view would.
    func transcribeUnifiedStreaming(_ samples: [Float]) async throws -> [CtcForcedAlignment.AlignedWord] {
        let streamer = StreamingUnifiedAsrManager()
        try await streamer.loadModels(to: locations.root.appendingPathComponent("unified"))
        var words: [WordTiming] = []
        var offset = 0
        while offset < samples.count {
            let count = min(16_000, samples.count - offset)
            guard let buffer = Self.slidingBuffer(samples[offset..<offset + count]) else { break }
            try await streamer.appendAudio(buffer)
            try await streamer.processBufferedAudio()
            words += await streamer.consumeWordTimings()
            offset += count
        }
        _ = try await streamer.finish()
        words += await streamer.consumeWordTimings()
        return words.map {
            CtcForcedAlignment.AlignedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
    }
}
