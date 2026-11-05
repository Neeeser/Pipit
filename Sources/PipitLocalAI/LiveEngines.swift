import Foundation
import PipitAudio
import PipitCore

/// One live engine for one track of one recording.
///
/// The caller hands it 16 kHz mono samples in timeline order and reads text
/// from `updates`. Every engine with a live path fits behind this, so the live
/// transcript does not care which one the person chose.
public protocol LiveTrackEngine: Sendable {
    /// Text as the engine produces it, in seconds on the recording's timeline.
    var updates: AsyncStream<LiveTextUpdate> { get }
    /// The next samples, starting `start` samples into the timeline. Calls
    /// for one engine are made one after another, never overlapping.
    func feed(_ samples: [Float], start: Int) async
    /// Settles whatever is still provisional and ends `updates`.
    func finish() async
}

public enum LiveEngineError: Error, Sendable, Equatable {
    /// The engine has no live path, or this Mac cannot run it.
    case unavailable
}

extension LocalModelManager {
    /// A live engine for one track, of the kind `engine` names.
    ///
    /// Throws when the engine cannot run live here: Apple's needs macOS 26,
    /// and Parakeet's needs its model and the voice detector installed.
    public func liveEngine(_ engine: LocalTranscriptionModel) async throws -> any LiveTrackEngine {
        switch engine.liveTranscription {
        case .streaming:
            #if compiler(>=6.2)
                if #available(macOS 26.0, *) { return try await AppleLiveEngine.start() }
            #endif
            throw LiveEngineError.unavailable
        case .phrases:
            let activity = try await liveVoiceActivity()
            _ = try await loadedParakeet()
            return ParakeetLiveEngine(models: self, activity: activity)
        case .none:
            throw LiveEngineError.unavailable
        }
    }
}

/// Parakeet cut at pauses: the voice detector closes a phrase after a short
/// silence and the phrase is transcribed on its own. While a phrase is still
/// open it is read again every couple of seconds, so words show up before the
/// speaker pauses and settle when the phrase closes.
public actor ParakeetLiveEngine: LiveTrackEngine {
    private static let window = LiveVoiceActivity.windowSamples
    /// Windows between provisional readings of an open phrase.
    private static let provisionalEvery = 8
    /// The shortest open phrase worth a provisional reading, in windows.
    private static let provisionalMinimum = 4
    /// A gap longer than this restarts the detector, as for echo removal.
    private static let restartGap = Int(2 * LiveTrackResampler.sampleRate)

    public nonisolated let updates: AsyncStream<LiveTextUpdate>
    private let publish: AsyncStream<LiveTextUpdate>.Continuation
    private let models: LocalModelManager
    private let activity: LiveVoiceActivity
    private var segmenter = LiveSpeechSegmenter(tuning: .live)
    /// Samples from `bufferStart`, the timeline index of the first one.
    private var buffer: [Float] = []
    private var bufferStart: Int?
    /// Timeline index of window zero.
    private var origin = 0
    /// Samples of `buffer` already scored by the voice detector.
    private var scored = 0
    private var lastProvisional = 0

    init(models: LocalModelManager, activity: LiveVoiceActivity) {
        self.models = models
        self.activity = activity
        (updates, publish) = AsyncStream<LiveTextUpdate>.makeStream()
    }

    public func feed(_ samples: [Float], start: Int) async {
        if let bufferStart, start - (bufferStart + buffer.count) > Self.restartGap {
            // A paused recording: settle the phrase that was open and start
            // again at the new position rather than scoring the silence.
            if let phrase = segmenter.finish() { await transcribe(phrase.start, phrase.end, isFinal: true) }
            segmenter = LiveSpeechSegmenter(tuning: .live)
            buffer = []
            scored = 0
            lastProvisional = 0
            self.bufferStart = nil
        }
        if bufferStart == nil {
            bufferStart = start
            origin = start
        }
        guard let bufferStart else { return }
        let end = bufferStart + buffer.count
        if start > end { buffer += [Float](repeating: 0, count: start - end) }
        if start >= end {
            buffer += samples
        } else if end - start < samples.count {
            buffer += samples[(end - start)...]
        }
        while buffer.count - scored >= Self.window {
            let window = Array(buffer[scored..<(scored + Self.window)])
            scored += Self.window
            let probability = (try? await activity.probability(window)) ?? 0
            if let phrase = segmenter.push(probability) {
                await transcribe(phrase.start, phrase.end, isFinal: true)
                trim(beforeWindow: phrase.end)
            } else if let open = segmenter.openPhraseStart {
                let length = segmenter.windowCount - open
                if length >= Self.provisionalMinimum, segmenter.windowCount - lastProvisional >= Self.provisionalEvery {
                    lastProvisional = segmenter.windowCount
                    await transcribe(open, segmenter.windowCount, isFinal: false)
                }
            } else {
                // The next phrase opens up to its padding before the window
                // that first sounds like speech, which is the next one.
                trim(beforeWindow: max(0, segmenter.windowCount - segmenter.tuning.paddingWindows - 1))
            }
        }
    }

    public func finish() async {
        if let phrase = segmenter.finish() {
            await transcribe(phrase.start, phrase.end, isFinal: true)
        }
        publish.finish()
    }

    /// Reads windows `from..<to` and publishes the text.
    private func transcribe(_ from: Int, _ to: Int, isFinal: Bool) async {
        guard let bufferStart else { return }
        let first = origin + from * Self.window - bufferStart
        let last = origin + to * Self.window - bufferStart
        let lower = max(0, first)
        let upper = min(buffer.count, last)
        guard upper > lower else { return }
        let start = Double(origin + from * Self.window) / LiveTrackResampler.sampleRate
        let end = Double(origin + to * Self.window) / LiveTrackResampler.sampleRate
        guard let phrase = try? await models.transcribeLivePhrase(Array(buffer[lower..<upper])) else {
            if isFinal { publish.yield(LiveTextUpdate(text: "", isFinal: true, start: start, end: end)) }
            return
        }
        publish.yield(LiveTextUpdate(text: phrase.text, isFinal: isFinal, start: start, end: end))
    }

    /// Drops samples before window `index`, which no phrase can reach back to.
    private func trim(beforeWindow index: Int) {
        guard let bufferStart else { return }
        let drop = min(origin + index * Self.window - bufferStart, scored)
        guard drop > 0 else { return }
        buffer.removeFirst(drop)
        scored -= drop
        self.bufferStart = bufferStart + drop
    }
}

#if compiler(>=6.2)
    /// Apple's SpeechAnalyzer behind the live engine interface. Its result
    /// times count from the first sample it was fed, so they are moved onto
    /// the recording's timeline here.
    @available(macOS 26.0, *)
    public actor AppleLiveEngine: LiveTrackEngine {
        public nonisolated let updates: AsyncStream<LiveTextUpdate>
        private let publish: AsyncStream<LiveTextUpdate>.Continuation
        private let transcriber: AppleLiveTranscriber
        private var fed: Int?
        private let offset = LockedBox<Double>(0)
        private var reader: Task<Void, Never>?

        static func start() async throws -> AppleLiveEngine {
            AppleLiveEngine(transcriber: try await AppleLiveTranscriber.start())
        }

        private init(transcriber: AppleLiveTranscriber) {
            self.transcriber = transcriber
            let (updates, publish) = AsyncStream<LiveTextUpdate>.makeStream()
            self.updates = updates
            self.publish = publish
            let offset = self.offset
            reader = Task {
                do {
                    for try await result in transcriber.results {
                        let shift = offset.withLock { $0 }
                        publish.yield(
                            LiveTextUpdate(
                                text: result.text, isFinal: result.isFinal,
                                start: result.start + shift, end: result.end + shift
                            ))
                    }
                } catch {
                    Log.processing.notice("live speech results stopped")
                }
                publish.finish()
            }
        }

        public func feed(_ samples: [Float], start: Int) async {
            if fed == nil {
                fed = start
                offset.withLock { $0 = Double(start) / LiveTrackResampler.sampleRate }
            }
            guard let next = fed else { return }
            // The analyzer counts time by samples fed, so a gap is fed as
            // silence to keep its clock on the recording's. A long one, from a
            // paused recording, is fed as two seconds and the rest is moved
            // into the offset, so minutes of silence are not analysed.
            if start > next {
                let limit = Int(2 * LiveTrackResampler.sampleRate)
                let silence = min(start - next, limit)
                await transcriber.feed([Float](repeating: 0, count: silence))
                let skipped = start - next - silence
                if skipped > 0 { offset.withLock { $0 += Double(skipped) / LiveTrackResampler.sampleRate } }
            }
            let skip = max(0, next - start)
            guard skip < samples.count else { return }
            await transcriber.feed(skip == 0 ? samples : Array(samples[skip...]))
            fed = max(next, start) + samples.count - skip
        }

        public func finish() async {
            try? await transcriber.finish()
            await reader?.value
        }
    }
#endif

/// The live engine the app runs during a call, over a whole recorded track,
/// keeping only the text the engine settled on.
///
/// A benchmark candidate, reachable through `pipit-eval bench --live-engine`
/// with `--engine apple` or `--engine parakeet`. It scores exactly what the
/// live window shows once each line has settled, so the engines can be
/// compared as live engines rather than as after-call passes.
public struct LiveEngineTranscriptionBackend: TranscriptionBackend {
    private let models: LocalModelManager
    private let engine: LocalTranscriptionModel

    public init(models: LocalModelManager, engine: LocalTranscriptionModel) {
        self.models = models
        self.engine = engine
    }

    public var identifier: String { engine.backendIdentifier + "-live" }
    public var isLocal: Bool { true }
    public var limits: BackendAudioLimits { .none }
    public var timing: TranscriptTiming { .segments }

    public func transcribe(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionOutput {
        let samples = try MonoAudioDecoder.loadMono16k(audio)
        let live = try await models.liveEngine(engine)
        let collector = Task {
            var settled: [LiveTextUpdate] = []
            for await update in live.updates where update.isFinal && !update.text.isEmpty {
                settled.append(update)
            }
            return settled
        }
        let step = Int(LiveTrackResampler.sampleRate)
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + step)
            await live.feed(Array(samples[offset..<end]), start: offset)
            offset = end
            progress(Double(offset) / Double(max(samples.count, 1)))
        }
        await live.finish()
        let settled = await collector.value.sorted { $0.start < $1.start }
        return TranscriptionOutput(
            segments: settled.map {
                RawTranscriptSegment(start: $0.start, end: $0.end, text: $0.text, speaker: nil)
            },
            text: settled.map(\.text).joined(separator: " "),
            durationSeconds: Double(samples.count) / LiveTrackResampler.sampleRate
        )
    }
}
