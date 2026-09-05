import AVFoundation
import Foundation
import PipitAudio
import PipitCore
import PipitIntegrations
import PipitLocalAI
import PipitServices
import PipitSpeakers
import Synchronization

/// A transcription backend with no model behind it, so the local path can be
/// exercised end to end without 650 MB of CoreML.
public final class StubLocalTranscriber: TranscriptionBackend, @unchecked Sendable {
    public var segments: [RawTranscriptSegment]
    /// What the microphone track says, where a test needs the two tracks to say
    /// different things. Identical words on both tracks are read as the far end
    /// reaching the microphone, and the local lines are dropped.
    public var micSegments: [RawTranscriptSegment]?
    public var identifier = "stub-whisper"
    public var isLocal = true
    public var limits = BackendAudioLimits.none
    public var timing = TranscriptTiming.words
    /// The audio handed to this backend, so a test can say which one read it.
    private let state = Mutex<[String]>([])
    public var received: [String] { state.withLock { $0 } }
    /// Where to keep a copy of every file handed over, for a test that has to
    /// measure the samples rather than read the name. The pipeline deletes its
    /// working copies when the meeting finishes, so they have to be taken as
    /// they are read.
    public var copyAudioTo: URL?
    private let copies = Mutex<[URL]>([])
    public var copiedAudio: [URL] { copies.withLock { $0 } }

    public init(segments: [RawTranscriptSegment]) { self.segments = segments }

    public func transcribe(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionOutput {
        state.withLock { $0.append(audio.lastPathComponent) }
        if let copyAudioTo {
            copies.withLock { made in
                let destination = copyAudioTo.appendingPathComponent(
                    "\(made.count).\(audio.lastPathComponent)"
                )
                try? FileManager.default.createDirectory(
                    at: copyAudioTo, withIntermediateDirectories: true
                )
                try? FileManager.default.copyItem(at: audio, to: destination)
                made.append(destination)
            }
        }
        progress(1)
        let spoken = audio.lastPathComponent.hasPrefix(CaptureTrack.mic.rawValue)
            ? (micSegments ?? segments) : segments
        return TranscriptionOutput(
            segments: spoken, text: spoken.map(\.text).joined(separator: " "),
            language: "en", durationSeconds: 6
        )
    }
}

public struct StubLocalDiarizer: DiarizationBackend, @unchecked Sendable {
    public var intervals: [DiarizationInterval]
    public var chunkEmbeddings: [DiarizationChunkEmbedding]
    public var identifier = "stub-fluidaudio"
    public var isLocal = true
    public var limits = BackendAudioLimits.none
    public var producesEmbeddings = true
    public var producesTranscript = false

    public init(intervals: [DiarizationInterval], chunkEmbeddings: [DiarizationChunkEmbedding]) {
        self.intervals = intervals
        self.chunkEmbeddings = chunkEmbeddings
    }

    public func diarize(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DiarizationOutput {
        progress(1)
        var speech: [String: Double] = [:]
        for interval in intervals { speech[interval.clusterID, default: 0] += interval.duration }
        return DiarizationOutput(
            intervals: intervals,
            clusters: speech.keys.sorted().map {
                DiarizationCluster(id: $0, speechSeconds: speech[$0] ?? 0)
            },
            chunkEmbeddings: chunkEmbeddings,
            configuration: ["warmStartFa": "0.2"]
        )
    }
}

/// A transcription backend that returns the best words and no timings, the
/// shape gpt-transcribe and local Cohere produce.
public final class StubTextTranscriber: TranscriptionBackend, @unchecked Sendable {
    public var text: String
    public var identifier = "stub-cohere"
    public var isLocal = true
    public var limits: BackendAudioLimits
    public var timing = TranscriptTiming.text
    private let state = Mutex<[String]>([])
    /// The audio handed to this backend, so a test can count its chunks.
    public var received: [String] { state.withLock { $0 } }

    public init(text: String, limits: BackendAudioLimits = .none) {
        self.text = text
        self.limits = limits
    }

    public func transcribe(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionOutput {
        state.withLock { $0.append(audio.lastPathComponent) }
        progress(1)
        return TranscriptionOutput(segments: [], text: text, durationSeconds: 6)
    }
}

/// An aligner with a fixed answer, or a refusal.
public struct StubAligner: TranscriptAligner, @unchecked Sendable {
    public var identifier = "stub-aligner"
    public var segments: [RawTranscriptSegment]
    public var refuses = false

    public init(segments: [RawTranscriptSegment], refuses: Bool = false) {
        self.segments = segments
        self.refuses = refuses
    }

    public func align(audio: URL, text: String) async throws -> [RawTranscriptSegment] {
        if refuses { throw TranscriptAlignmentRefused(reason: "stub refusal") }
        return segments
    }
}

/// Stands in for the embedding extractor on a machine with no models installed.
public struct RefusingEmbeddingExtractor: SpeakerEmbeddingExtractor {
    public init() {}

    public var model: EmbeddingModelIdentifier { .fluidAudioOffline }

    public func embed(audio: URL, intervals: [DiarizationInterval]) async throws -> [DiarizationChunkEmbedding] {
        throw LocalModelError.notInstalled
    }
}

/// A finished recording on disk, and the pipelines that process one.
public enum PipelineFixtures {
    /// Builds a finished two-track recording on disk, ready for processing.
    public static func makeRecordedMeeting(
        root: URL, source: MeetingSource = .googleMeet, seconds: Double = 6,
        remoteStartOffset: Double = 0, amplitude: Float = 0.5
    ) throws -> (metadata: MeetingMetadata, store: MeetingStore, repository: MeetingRepository) {
        let repository = MeetingRepository(root: root)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: source, provider: source.provider, startedAt: started,
            titles: TitleCandidates(provider: "Weekly sync", timestampFallback: "fallback"),
            now: started
        )

        let manifest = try ManifestWriter(url: created.store.layout.manifest)
        manifest.append(.sessionStart(.init(
            meetingID: created.metadata.id, source: source, segmentSeconds: 30,
            appVersion: "test", processID: 1
        )))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let micWriter = SegmentWriter(
            track: .mic, layout: created.store.layout, manifest: manifest,
            format: format, segmentSeconds: 30
        )
        micWriter.enqueueSynchronously(AudioBufferPacket(
            buffer: AudioFixtures.makeTone(seconds: seconds, sampleRate: 48_000, amplitude: amplitude),
            hostTime: 100
        ))
        micWriter.finish(reason: "test")

        if source.capturesRemoteAudio {
            let remoteWriter = SegmentWriter(
                track: .remote, layout: created.store.layout, manifest: manifest,
                format: format, segmentSeconds: 30
            )
            remoteWriter.enqueueSynchronously(AudioBufferPacket(
                buffer: AudioFixtures.makeTone(
                    seconds: seconds, sampleRate: 48_000, frequency: 220, amplitude: amplitude
                ),
                hostTime: 100 + remoteStartOffset
            ))
            remoteWriter.finish(reason: "test")
        }
        manifest.append(.sessionEnd(.init(reason: "test", micSeconds: seconds, remoteSeconds: seconds)))
        manifest.close()

        var metadata = created.metadata
        metadata.endedAt = started.addingTimeInterval(seconds)
        metadata.durationSeconds = seconds
        metadata.runs = [RecordingRun(
            id: "run-001", startedAt: started, endedAt: metadata.endedAt, durationSeconds: seconds
        )]
        metadata.processing = ProcessingStatus(state: .audioSafe, updatedAt: started)
        try created.store.writeMetadata(metadata)
        return (metadata, created.store, repository)
    }

    public static func makePipeline(
        repository: MeetingRepository, backend: FakeAIBackend, settings: AppSettings = AppSettings()
    ) -> ProcessingPipeline {
        ProcessingPipeline(
            repository: repository,
            backend: backend,
            clock: ManualClock(),
            settingsProvider: { settings },
            wait: { _ in }
        )
    }

    public static func makePipeline(
        repository: MeetingRepository,
        backend: FakeAIBackend,
        transcriber: any TranscriptionBackend,
        diarizer: StubLocalDiarizer,
        speakers: SpeakerRecognitionService?,
        aligner: (any TranscriptAligner)? = nil,
        prepareAligner: (@Sendable () async throws -> Void)? = nil,
        singleSpeakerEmbedding: (@Sendable (URL) async throws -> SingleSpeakerSample?)? = nil,
        settings: AppSettings,
        scratchRoot: URL,
        onProgress: @escaping @Sendable (ProcessingPipeline.Progress) -> Void = { _ in }
    ) -> ProcessingPipeline {
        ProcessingPipeline(
            repository: repository,
            backend: backend,
            backends: ProcessingBackends(
                transcription: { _, _ in transcriber },
                diarization: { _, _ in diarizer },
                speakers: speakers,
                aligner: aligner,
                prepareAligner: prepareAligner,
                singleSpeakerEmbedding: singleSpeakerEmbedding
            ),
            scratch: ProcessingScratch(root: scratchRoot),
            clock: ManualClock(),
            settingsProvider: { settings },
            onProgress: onProgress,
            wait: { _ in }
        )
    }
}
