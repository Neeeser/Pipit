import CoreML
import FluidAudio
import Foundation
import PipitAudio
import PipitCore

/// On-device diarization with NVIDIA's Nemotron 3 Diarization model through
/// FluidAudio. Like LS-EEND it emits per-speaker activity frame by frame, so
/// two people talking at once stay two overlapping intervals; it tracks at
/// most eight speakers.
///
/// `LocalDiarizationBackend` wraps the `offline` preset as the diarizer a
/// finished meeting uses, with the offline clusterer behind it. The bench
/// reaches this one directly through `pipit-eval bench --diarizer nemotron3`,
/// with no fallback, to measure the model alone. It reports no embeddings;
/// voice memory embeds its intervals with the same extractor that covers the
/// cloud diarizer.
public struct Nemotron3DiarizationBackend: DiarizationBackend {
    /// FluidAudio's presets. `offline` is the full-context preset the
    /// application uses; `fast128` trades accuracy headroom for speed and
    /// scored the same on the first five calls, and only the bench builds it.
    public enum Preset: String, Sendable, CaseIterable {
        case offline
        case fast128

        var configuration: Nemotron3Config {
            switch self {
            case .offline: .offline
            case .fast128: .fast128
            }
        }
    }

    private let models: LocalModelManager
    private let preset: Preset

    public init(models: LocalModelManager, preset: Preset = .offline) {
        self.models = models
        self.preset = preset
    }

    public var identifier: String { Self.identifier(for: preset) }
    public var isLocal: Bool { true }
    public var limits: BackendAudioLimits { .none }
    public var producesEmbeddings: Bool { false }
    public var producesTranscript: Bool { false }

    static func identifier(for preset: Preset) -> String {
        "\(LocalSpeechStack.nemotron3BackendIdentifierPrefix)\(preset.rawValue)-0.18.2"
    }

    public func diarize(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DiarizationOutput {
        try await models.nemotron3Diarize(audio: audio, preset: preset, progress: progress)
    }

    /// The timeline in the pipeline's terms: one interval per segment, one
    /// cluster per speaker slot, and overlapping segments from different
    /// speakers kept overlapping. The model reports no per-segment confidence,
    /// so every interval carries full quality.
    public static func output(
        segments: [(speaker: Int, start: Double, end: Double)],
        configuration: [String: String]
    ) -> DiarizationOutput {
        let intervals =
            segments
            .map {
                DiarizationInterval(
                    start: $0.start, end: $0.end,
                    clusterID: "nemotron3_\($0.speaker)", quality: 1
                )
            }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.clusterID < $1.clusterID
            }
        var speech: [String: Double] = [:]
        for interval in intervals { speech[interval.clusterID, default: 0] += interval.duration }
        let clusters = speech.keys.sorted().map {
            DiarizationCluster(id: $0, speechSeconds: speech[$0] ?? 0, quality: 1, chunkCount: 0)
        }
        return DiarizationOutput(
            intervals: intervals, clusters: clusters, configuration: configuration
        )
    }

    /// Whether the audio holds nothing the model could place a speaker in:
    /// shorter than the model's shortest reported turn, or no louder than the
    /// noise floor of an idle device. A tap that wrote digital zero for a whole
    /// call is the real case. The model never sees such a file, so a meeting
    /// where nobody spoke gets an empty diarization, the answer the offline
    /// clusterer gives through `LocalModelManager.silentMeeting`.
    static func isEffectivelySilent(_ samples: [Float]) -> Bool {
        guard samples.count >= minimumSamples else { return true }
        var peak: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
            if peak >= silencePeak { return false }
        }
        return true
    }

    /// 0.2 s at 16 kHz, the shortest segment `Nemotron3Diarizer.segments`
    /// reports.
    static let minimumSamples = 3_200
    /// About -80 dBFS: digital zero and dither, below any voice a microphone
    /// or tap would carry.
    static let silencePeak: Float = 1e-4

    /// Longest file the model is given, in seconds: three hours.
    ///
    /// A pass decodes the whole file to floats and builds the full mel matrix,
    /// so memory grows with the meeting. Measured on synthetic 16 kHz files
    /// (debug build, process peak footprint including the loaded model): about
    /// 0.7 GB for one hour and 1.9 GB for three, roughly 0.6 GB per hour. The
    /// cap keeps a pass near 2 GB; a longer file goes to the clusterer, which
    /// streams from disk. Only the 34-minute case was measured with real
    /// audio.
    static let maximumSeconds: Double = 3 * 3_600

    /// Why Nemotron declines a file without trying it. `LocalDiarizationBackend`
    /// sends these to the clusterer.
    enum Unsupported: Error {
        case audioTooLong
    }

    /// Whether the model reported a speaker in every slot it has. A meeting
    /// with that many voices may hold more than the model can keep apart, and
    /// two people sharing a slot cannot be split afterwards.
    static func fillsEverySlot(_ output: DiarizationOutput) -> Bool {
        output.clusters.count >= LocalSpeechStack.nemotron3SpeakerSlots
    }

    static func provenance(preset: Preset) -> [String: String] {
        [
            "backend": identifier(for: preset),
            "pipeline": "nemotron3",
            "variant": preset.rawValue,
            "package": LocalSpeechStack.diarizerPackage,
            "diarizer": "nemotron3",
        ]
    }
}

extension LocalModelManager {
    /// Where Nemotron 3's Core ML models compute: the CPU and the Neural
    /// Engine, never the GPU.
    ///
    /// Core ML's GPU path runs the model through MPSGraph. In a run of about 40
    /// diarizations on one Mac, two predictions raised an Objective-C
    /// `NSGenericException` from that path ("MPSGraph tensor shape is missing
    /// or has unexpected rank (expected 3, got 0)"), which Swift cannot catch
    /// and which ends the whole process. Both happened while another model was
    /// using the GPU. A meeting finishing while a call, a video or another
    /// model holds the GPU is the ordinary case, so the GPU stays out.
    public static let nemotron3ComputeUnits: MLComputeUnits = .cpuAndNeuralEngine

    /// Whether the preset's bundle and its silence embedding are on disk for
    /// the checkpoint this FluidAudio build expects. Anything else would make
    /// the library delete the folder and download again, which a meeting being
    /// processed must not start.
    static func nemotron3FilesPresent(
        _ preset: Nemotron3DiarizationBackend.Preset, directory: URL
    ) -> Bool {
        let manager = FileManager.default
        let config = preset.configuration
        let bundle = directory.appendingPathComponent(
            "\(config.hubSubdirectory)/\(config.modelFileName)/coremldata.bin"
        )
        let embedding = directory.appendingPathComponent(ModelNames.Nemotron3.silenceEmbeddingFile)
        let marker = directory.appendingPathComponent(ModelNames.Nemotron3.weightsVersionFile)
        let version = (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return manager.fileExists(atPath: bundle.path)
            && manager.fileExists(atPath: embedding.path)
            && version == ModelNames.Nemotron3.weightsVersion
    }

    /// Fetches the `offline` preset and loads it once, so the first meeting
    /// pays neither the download nor the Core ML compile.
    func installNemotron3(
        force: Bool, progress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        if force { try? FileManager.default.removeItem(at: locations.nemotronDiarizerDirectory) }
        progress(0, "Downloading speaker models")
        _ = try await Nemotron3Models.loadFromHuggingFace(
            config: .offline, cacheDirectory: locations.root,
            computeUnits: Self.nemotron3ComputeUnits,
            progressHandler: { update in
                progress(update.fractionCompleted * 0.9, "Downloading speaker models")
            }
        )
    }

    /// Diarizes one file with Nemotron 3. Runs go through `nemotron3Runs`, one
    /// at a time: the actor lets a second call start while the first awaits
    /// its detached task, so the actor alone does not keep two meetings from
    /// holding two decoded copies and two models at once.
    ///
    /// The application's `offline` preset must already be installed, and this
    /// throws `LocalModelError.notInstalled` rather than download it. The
    /// bench-only presets fetch on first use, so selecting one is the consent
    /// for its download.
    func nemotron3Diarize(
        audio: URL, preset: Nemotron3DiarizationBackend.Preset,
        maximumSeconds: Double = Nemotron3DiarizationBackend.maximumSeconds,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DiarizationOutput {
        try Task.checkCancellation()
        let modelLease = lease()
        defer { modelLease.release() }
        let root = locations.root
        if preset == .offline,
            !Self.nemotron3FilesPresent(preset, directory: locations.nemotronDiarizerDirectory)
        {
            throw LocalModelError.notInstalled
        }
        guard MonoAudioDecoder.durationSeconds(audio) <= maximumSeconds
        else { throw Nemotron3DiarizationBackend.Unsupported.audioTooLong }
        return try await Self.nemotron3Runs.run {
            var provenance = Nemotron3DiarizationBackend.provenance(preset: preset)
            progress(0.02)
            let samples = try MonoAudioDecoder.loadMono16k(audio)
            try Task.checkCancellation()
            guard !Nemotron3DiarizationBackend.isEffectivelySilent(samples) else {
                provenance["silentAudio"] = "true"
                progress(1)
                return DiarizationOutput(intervals: [], clusters: [], configuration: provenance)
            }
            progress(0.15)
            let config = preset.configuration
            let models = try await Nemotron3Models.loadFromHuggingFace(
                config: config, cacheDirectory: root,
                computeUnits: LocalModelManager.nemotron3ComputeUnits
            )
            // The prediction loop below cannot be interrupted, so this is the
            // last point where a cancelled job stops without finishing it.
            try Task.checkCancellation()
            progress(0.4)
            let diarizer = Nemotron3Diarizer(config: config, models: models)
            let result = try diarizer.processComplete(samples)
            let found = Nemotron3Diarizer.segments(
                probabilities: result.probabilities, frameCount: result.frameCount
            )
            progress(1)
            return Nemotron3DiarizationBackend.output(
                segments: found.map {
                    (
                        speaker: $0.speakerIndex,
                        start: Double($0.startSeconds), end: Double($0.endSeconds)
                    )
                },
                configuration: provenance
            )
        }
    }

    /// Every Nemotron run in the process, one at a time.
    static let nemotron3Runs = Nemotron3RunQueue()
}

/// Runs Nemotron jobs one after another and passes a caller's cancellation on
/// to the job.
///
/// The model is not `Sendable`, so each job keeps it inside one detached task
/// and only the Sendable output crosses back. That task is not a child of the
/// caller, so cancelling the caller does nothing to it unless this forwards the
/// cancellation, and two callers' tasks run side by side unless something
/// orders them.
actor Nemotron3RunQueue {
    private var tail: Task<Void, Never>?

    func run<Output: Sendable>(
        _ work: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        let previous = tail
        let task = Task.detached(priority: .userInitiated) { () async throws -> Output in
            await previous?.value
            try Task.checkCancellation()
            return try await work()
        }
        // Set before the first suspension, so the next caller waits on this one.
        tail = Task { _ = await task.result }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
