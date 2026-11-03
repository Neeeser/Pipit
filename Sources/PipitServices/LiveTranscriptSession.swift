import Foundation
import PipitAudio
import PipitCore
import PipitLocalAI
import PipitSpeakers

/// The live transcript of one recording, from the first buffer to stop.
///
/// Capture hands every buffer it saves to `sink`, which only queues it: the
/// audio threads never wait on anything here. A queue that falls behind drops
/// its oldest buffers, which costs live text and nothing else, because the
/// recording on disk is written by the segment writers before this sees the
/// buffer.
///
/// From the queue each track is resampled to 16 kHz mono on one timeline. The
/// microphone is cleaned of the far end, both tracks go to the chosen engine,
/// and the far end is written to a scratch file a speaker pass reads every
/// minute or so to label who spoke. None of it is the meeting's transcript:
/// the pass over the whole recording writes that after the call.
actor LiveTranscriptSession {
    typealias Item = (packet: AudioBufferPacket, track: CaptureTrack)

    /// Enough for several seconds of buffers on both tracks, so a pause while
    /// a model loads loses nothing; past it the oldest go first.
    private static let queueLimit = 1_000

    nonisolated let sink: CaptureEngine.LiveAudioSink
    private let stream: AsyncStream<Item>
    private let input: AsyncStream<Item>.Continuation

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

    init(
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
        let (stream, input) = AsyncStream<Item>.makeStream(bufferingPolicy: .bufferingNewest(Self.queueLimit))
        self.stream = stream
        self.input = input
        sink = { packet, track in input.yield((packet, track)) }
    }

    /// Loads the engines and starts reading the queue. Buffers that arrive
    /// while the engines load wait in the queue.
    func start() async {
        do {
            for track in CaptureTrack.allCases {
                engines[track] = try await models.liveEngine(engineChoice)
            }
        } catch {
            Log.processing.notice("live transcript unavailable: \(String(describing: error), privacy: .public)")
            engines = [:]
            input.finish()
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
    func stop() async {
        input.finish()
        await consumer?.value
        consumer = nil
        speakerLoop?.cancel()
        await speakerLoop?.value
        speakerLoop = nil
        if let echo, let cleaned = echo.flush(), let engine = engines[.mic] {
            await engine.feed(cleaned.samples, start: cleaned.start)
        }
        for engine in engines.values { await engine.finish() }
        for reader in readers { await reader.value }
        readers = []
        engines = [:]
        farEnd = nil
        try? FileManager.default.removeItem(at: scratch)
        await model.setState(.ended)
    }

    private func consume() async {
        for await item in stream {
            let origin = self.origin ?? item.packet.hostTime
            self.origin = origin
            let resampler = resamplers[item.track] ?? LiveTrackResampler(origin: origin)
            resamplers[item.track] = resampler
            guard let converted = resampler.convert(item.packet) else { continue }
            heard = max(heard, converted.start + converted.samples.count)
            switch item.track {
            case .remote:
                echo?.addReference(converted.samples, start: converted.start)
                writeFarEnd(converted.samples, start: converted.start)
                await engines[.remote]?.feed(converted.samples, start: converted.start)
            case .mic:
                if let echo {
                    if let cleaned = echo.addMicrophone(converted.samples, start: converted.start) {
                        await engines[.mic]?.feed(cleaned.samples, start: cleaned.start)
                    }
                } else {
                    await engines[.mic]?.feed(converted.samples, start: converted.start)
                }
            }
            let seconds = Double(heard) / LiveTrackResampler.sampleRate
            if seconds - lastReported >= 0.5 {
                lastReported = seconds
                await model.advance(to: seconds)
            }
        }
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

    /// Runs a speaker pass over the far end so far, every minute at first and
    /// less often as the call grows, since each pass covers all of it.
    private func labelSpeakers() async {
        var wait: Double = 45
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await labelOnce()
            let seconds = Double(heard) / LiveTrackResampler.sampleRate
            wait = seconds < 20 * 60 ? 60 : seconds < 60 * 60 ? 120 : 240
        }
    }

    private func labelOnce() async {
        guard let farEnd, let first = farEndStart, farEnd.seconds >= 20 else { return }
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
            Log.processing.notice("live speaker pass skipped")
        }
    }

    private static func reason(for engine: LocalTranscriptionModel) -> String {
        switch engine {
        case .apple: "Live text needs macOS 26 or later."
        case .parakeet: "Live text needs the Parakeet model. Install it in Settings."
        default: "Live text is not available for this engine."
        }
    }
}
