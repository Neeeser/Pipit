import Foundation
import PipitAudio
import PipitCore
import PipitLocalAI
import PipitSpeakers

/// The live transcript of one recording, from the first buffer to stop.
///
/// Capture pushes every buffer it saves into `queue`, and the audio threads
/// do nothing more: this drains the queue on its own schedule. A queue that
/// fills drops new buffers, which costs live text and nothing else, because
/// the recording on disk is written by the segment writers before this sees
/// the buffer.
///
/// From the queue each track is resampled to 16 kHz mono on one timeline. The
/// microphone is cleaned of the far end, both tracks go to the chosen engine,
/// and the far end is written to a scratch file that speaker passes read,
/// from about 20 seconds in, to label who spoke. None of it is the meeting's transcript:
/// the pass over the whole recording writes that after the call.
public actor LiveTranscriptSession {
    /// About a minute of buffers on both tracks at the rates the sources
    /// deliver, so a model load or a speaker pass loses nothing.
    private static let queueCapacity = 8_000
    /// How long the reader waits when the queue is empty.
    private static let pollNanoseconds: UInt64 = 20_000_000

    public nonisolated let queue = LiveAudioQueue(capacity: LiveTranscriptSession.queueCapacity)
    private var stopping = false
    private var dropped = 0
    /// What the replay harness reads: buffers dropped and audio processed.
    public private(set) var processedSeconds: Double = 0
    public var droppedBuffers: Int { dropped }
    /// Speaker passes run so far, for the replay harness.
    public private(set) var speakerPasses = 0

    private let meetingID: String
    private let engineChoice: LocalTranscriptionModel
    private let models: LocalModelManager
    private let speakers: SpeakerRecognitionService?
    private let speakerSettings: SpeakerRecognitionSettings
    private let scratch: URL
    private let model: LiveTranscriptModel

    private var origin: Double?
    private var resamplers: [CaptureTrack: LiveTrackResampler] = [:]
    private var echo: LiveEchoRemover?
    private var engines: [CaptureTrack: any LiveTrackEngine] = [:]
    /// Audio on its way to each engine. The reader hands samples over and
    /// moves on, so an engine waiting for the speech model, held by another
    /// meeting's processing, does not stop the other track or echo removal.
    private var feeds: [CaptureTrack: AsyncStream<EngineChunk>.Continuation] = [:]
    private var feeders: [Task<Void, Never>] = []
    struct EngineChunk: Sendable {
        var samples: [Float]
        var start: Int
    }
    /// About ten minutes of one-buffer chunks per engine before the oldest
    /// are dropped, off the audio threads.
    private static let engineBacklog = 60_000
    private var readers: [Task<Void, Never>] = []
    private var consumer: Task<Void, Never>?
    private var speakerLoop: Task<Void, Never>?
    private var farEnd: GrowingWaveFile?
    /// Timeline index of the scratch file's first sample.
    private var farEndStart: Int?
    private var farEndWritten = 0
    private var heard = 0
    private var turns: [LiveSpeakerTurn] = []
    private var usedLabels: Set<String> = []
    private var lastReported: Double = 0

    public init(
        meetingID: String, engine: LocalTranscriptionModel, models: LocalModelManager,
        speakers: SpeakerRecognitionService?, speakerSettings: SpeakerRecognitionSettings,
        scratch: URL, model: LiveTranscriptModel
    ) {
        self.meetingID = meetingID
        self.engineChoice = engine
        self.models = models
        self.speakers = speakers
        self.speakerSettings = speakerSettings
        self.scratch = scratch
        self.model = model
    }

    /// Loads the engines and starts reading the queue. Buffers that arrive
    /// while the engines load wait in the queue.
    public func start() async {
        do {
            for track in CaptureTrack.allCases {
                engines[track] = try await models.liveEngine(engineChoice)
            }
        } catch {
            Log.processing.notice(
                "live transcript unavailable: \(String(describing: type(of: error)), privacy: .public)")
            engines = [:]
            stopping = true
            await model.setState(.unavailable(Self.reason(for: engineChoice)))
            return
        }
        do {
            echo = try LiveEchoRemover()
        } catch {
            // Without it the microphone's live text also carries the far end
            // on a call taken on speakers; the saved transcript is unaffected.
            Log.processing.notice("live echo removal unavailable")
        }
        for (track, engine) in engines {
            let (chunks, feed) = AsyncStream<EngineChunk>.makeStream(
                bufferingPolicy: .bufferingNewest(Self.engineBacklog)
            )
            feeds[track] = feed
            feeders.append(
                Task {
                    for await chunk in chunks { await engine.feed(chunk.samples, start: chunk.start) }
                })
            let model = self.model
            readers.append(
                Task {
                    for await update in engine.updates {
                        await model.apply(update, track: track)
                    }
                })
        }
        await model.setState(.live)
        consumer = Task { await self.consume() }
        speakerLoop = Task { await self.labelSpeakers() }
    }

    /// Stops reading, settles the provisional text, and removes the scratch
    /// file. Safe to call more than once.
    public func stop() async {
        stopping = true
        await consumer?.value
        consumer = nil
        speakerLoop?.cancel()
        await speakerLoop?.value
        speakerLoop = nil
        if let echo, let cleaned = echo.flush() { send(cleaned.samples, start: cleaned.start, to: .mic) }
        for feed in feeds.values { feed.finish() }
        for feeder in feeders { await feeder.value }
        feeds = [:]
        feeders = []
        for engine in engines.values { await engine.finish() }
        for reader in readers { await reader.value }
        readers = []
        engines = [:]
        farEnd = nil
        try? FileManager.default.removeItem(at: scratch)
        if dropped > 0 {
            Log.processing.notice("live transcript dropped \(self.dropped, privacy: .public) buffers")
        }
        await model.setState(.ended)
    }

    private func consume() async {
        while true {
            let batch = queue.drain()
            if batch.dropped > 0 {
                if dropped == 0 { Log.processing.notice("live transcript fell behind and dropped audio") }
                dropped += batch.dropped
            }
            if batch.items.isEmpty {
                if stopping { return }
                try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
                continue
            }
            for item in batch.items { await process(item) }
        }
    }

    private func process(_ item: LiveAudioItem) async {
        let origin = self.origin ?? item.packet.hostTime
        self.origin = origin
        let resampler = resamplers[item.track] ?? LiveTrackResampler(origin: origin)
        resamplers[item.track] = resampler
        guard let converted = resampler.convert(item.packet) else { return }
        heard = max(heard, converted.start + converted.samples.count)
        switch item.track {
        case .remote:
            echo?.addReference(converted.samples, start: converted.start)
            writeFarEnd(converted.samples, start: converted.start)
            send(converted.samples, start: converted.start, to: .remote)
        case .mic:
            if let echo {
                if let cleaned = echo.addMicrophone(converted.samples, start: converted.start) {
                    send(cleaned.samples, start: cleaned.start, to: .mic)
                }
            } else {
                send(converted.samples, start: converted.start, to: .mic)
            }
        }
        let seconds = Double(heard) / LiveTrackResampler.sampleRate
        processedSeconds = seconds
        if seconds - lastReported >= 0.5 {
            lastReported = seconds
            // Posted, not awaited: the main thread can be held for seconds by
            // an open menu or a window appearing, and the reader waiting on it
            // let the queue fill behind it. The window catches up when the
            // main thread does.
            let model = self.model
            Task { @MainActor in model.advance(to: seconds) }
        }
    }

    private func send(_ samples: [Float], start: Int, to track: CaptureTrack) {
        feeds[track]?.yield(EngineChunk(samples: samples, start: start))
    }

    private func writeFarEnd(_ samples: [Float], start: Int) {
        do {
            if farEnd == nil {
                farEnd = try GrowingWaveFile(url: scratch.appendingPathComponent("far-end.wav"))
                farEndStart = start
            }
            guard let farEnd, let first = farEndStart else { return }
            let position = first + farEndWritten
            if start > position {
                // A gap is silence, so the file's clock stays the timeline's.
                let gap = [Float](repeating: 0, count: start - position)
                try farEnd.append(gap)
                farEndWritten += gap.count
            }
            let skip = max(0, position - start)
            guard skip < samples.count else { return }
            let kept = skip == 0 ? samples : Array(samples[skip...])
            try farEnd.append(kept)
            farEndWritten += kept.count
        } catch {
            Log.processing.notice("live speaker audio could not be written")
            farEnd = nil
        }
    }

    /// Runs a speaker pass over the far end so far. The first runs as soon as
    /// there is enough audio to tell voices apart, so lines get names early in
    /// the call. After that the wait is a multiple of how long the last pass
    /// took: each pass covers the whole call so far, so passes slow down as it
    /// grows, and the multiple keeps them from occupying the models.
    private func labelSpeakers() async {
        var wait = Self.speakerPassPoll
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let started = Date()
            guard await labelOnce() else {
                wait = Self.speakerPassPoll
                continue
            }
            let took = Date().timeIntervalSince(started)
            wait = min(Self.speakerPassLongestWait, max(Self.speakerPassShortestWait, took * 4))
        }
    }

    /// How often to check whether there is enough far end for a first pass.
    private static let speakerPassPoll: Double = 5
    private static let speakerPassShortestWait: Double = 20
    private static let speakerPassLongestWait: Double = 240

    /// One speaker pass. False when there was too little far end to run one.
    private func labelOnce() async -> Bool {
        guard let farEnd, let first = farEndStart, farEnd.seconds >= 20 else { return false }
        defer { speakerPasses += 1 }
        do {
            try farEnd.seal()
            let output = try await models.diarizeLive(audio: farEnd.url)
            let offset = Double(first) / LiveTrackResampler.sampleRate
            let intervals = output.intervals.map {
                LiveSpeakerLabels.Interval(start: $0.start + offset, end: $0.end + offset, cluster: $0.clusterID)
            }
            let stable = LiveSpeakerLabels.stabilize(previous: turns, intervals: intervals, used: usedLabels)
            turns = stable.turns
            usedLabels.formUnion(stable.labels.values)
            var names: [String: String] = [:]
            if let speakers {
                let clusters = output.clusters.map { cluster in
                    SpeakerClusterInput(
                        clusterID: cluster.id, track: .remote, speechSeconds: cluster.speechSeconds,
                        centroid: VoiceVector.centroid(
                            output.chunkEmbeddings.filter { $0.clusterID == cluster.id }.map(\.vector)
                        ),
                        quality: cluster.quality,
                        spans: output.intervals.filter { $0.clusterID == cluster.id }.map {
                            AudioSpan(start: $0.start, end: $0.end)
                        }
                    )
                }
                let byCluster = try await speakers.liveNames(
                    meetingID: meetingID, clusters: clusters, settings: speakerSettings
                )
                for (cluster, name) in byCluster {
                    if let label = stable.labels[cluster] { names[label] = name }
                }
            }
            await model.label(turns: turns, names: names)
        } catch {
            Log.processing.notice("live speaker pass skipped: \(String(describing: type(of: error)), privacy: .public)")
        }
        return true
    }

    private static func reason(for engine: LocalTranscriptionModel) -> String {
        switch engine {
        case .apple: "Live text needs macOS 26 or later."
        case .parakeet: "Live text needs the Parakeet model. Install it in Settings."
        default: "Live text is not available for this engine."
        }
    }
}
