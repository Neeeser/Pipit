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
    ///
    /// The file is decoded block by block and only as far as the answer needs.
    /// Audio with a voice in it is audible within its first block, so a meeting
    /// of any length costs one block of decoding. Also returns how many samples
    /// it read.
    static func isEffectivelySilent(audio: URL) throws -> (silent: Bool, samplesRead: Int) {
        var probe = SilenceProbe()
        try MonoAudioDecoder.forEachBlock(audio) { probe.add($0) }
        return (probe.isSilent, probe.samples)
    }

    /// Counts samples and watches for one audible one, block by block.
    struct SilenceProbe {
        private(set) var samples = 0
        private(set) var heardSound = false

        var isSilent: Bool { !heardSound || samples < minimumSamples }

        /// Takes the next block and returns whether more could change the answer.
        mutating func add(_ block: [Float]) -> Bool {
            samples += block.count
            if !heardSound { heardSound = block.contains { abs($0) >= silencePeak } }
            return !heardSound || samples < minimumSamples
        }
    }

    /// 0.2 s at 16 kHz, the shortest segment `Nemotron3Diarizer.segments`
    /// reports.
    static let minimumSamples = 3_200
    /// About -80 dBFS: digital zero and dither, below any voice a microphone
    /// or tap would carry.
    static let silencePeak: Float = 1e-4

    /// Runs the model over a file while it decodes, one block at a time.
    ///
    /// FluidAudio's `processComplete` takes the whole file as floats and builds
    /// its full mel matrix before the first prediction, so its memory grew
    /// with the meeting, about 0.6 GB per hour, and Pipit refused files over
    /// three hours. The streaming calls run the same chunks in the same order
    /// with the same speaker state, so the output matches a whole-file pass,
    /// and the eight speaker slots carry across the whole file: a person keeps
    /// one label for the whole meeting, however long it runs. What still grows
    /// with length is the per-frame speaker activity, eight floats every 10 ms,
    /// about 12 MB per hour.
    static func streamedSegments(
        audio: URL, diarizer: Nemotron3Diarizer, progress: (Double) -> Void
    ) throws -> [Nemotron3Segment] {
        let expectedSamples = max(MonoAudioDecoder.durationSeconds(audio) * 16_000, 1)
        var probabilities: [Float] = []
        probabilities.reserveCapacity(Int(expectedSamples / 160) * LocalSpeechStack.nemotron3SpeakerSlots)
        var frames = 0
        var fed = 0
        func keep(_ chunks: [Nemotron3ChunkResult]) {
            for chunk in chunks {
                probabilities.append(contentsOf: chunk.probabilities)
                frames += chunk.frameCount
            }
        }
        try MonoAudioDecoder.forEachBlock(audio) { block in
            try Task.checkCancellation()
            diarizer.appendAudio(block)
            keep(try diarizer.processBufferedAudio())
            fed += block.count
            progress(min(Double(fed) / expectedSamples, 1))
            return true
        }
        keep(try diarizer.finishStream())
        return Nemotron3Diarizer.segments(probabilities: probabilities, frameCount: frames)
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

    /// Written beside the weights-version marker once the Core ML compile has
    /// finished, holding the weights version it compiled, so a launch can tell a
    /// compile that never ran from one that did.
    static let nemotron3CompileMarkerFile = "pipit-compile-finished"

    static func nemotron3CompileFinished(directory: URL) -> Bool {
        let marker = directory.appendingPathComponent(nemotron3CompileMarkerFile)
        let version = (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return version == ModelNames.Nemotron3.weightsVersion
    }

    /// Starts the background compile at launch for an install that has the
    /// files and no record that the compile finished, such as one the app quit
    /// during. A compile that already happened loads in well under a second, so
    /// an install from before the marker existed pays almost nothing.
    public func resumeNemotronPreparation() {
        let directory = locations.nemotronDiarizerDirectory
        guard receipts[.nemotronDiarizer] != nil,
            !Self.nemotron3CompileFinished(directory: directory)
        else { return }
        startNemotronPreparation()
    }

    /// Compiles the model for the Neural Engine in the background, so the first
    /// meeting after an install does not wait for it.
    ///
    /// Core ML caches the compiled model by location, and the first load in a
    /// new place takes minutes. This runs once after the unit installs, at low
    /// priority and detached from the install, so recording, processing and
    /// the install's own completion never wait on it. A meeting that finishes
    /// first waits for this one in `nemotron3Diarize` instead of starting a
    /// second compile beside it. It holds a lease, so the idle release waits
    /// for it too.
    func startNemotronPreparation() {
        if let running = nemotronPreparation, !running.isCancelled { return }
        guard Self.nemotron3FilesPresent(.offline, directory: locations.nemotronDiarizerDirectory)
        else { return }
        nemotronPreparationGeneration &+= 1
        let generation = nemotronPreparationGeneration
        onPreparationChange(true)
        let modelLease = lease()
        let source = nemotron
        let root = locations.root
        nemotronPreparation = Task.detached(priority: .background) { [weak self] in
            var compiled = false
            do {
                let seconds = try await source.prepare(root: root)
                compiled = !Task.isCancelled
                Log.processing.info("nemotron prepared seconds=\(seconds, privacy: .public)")
            } catch {
                // The meeting path loads the model itself, so a failure here
                // costs the first meeting the wait and nothing else.
                Log.processing.notice(
                    "nemotron preparation failed error=\(String(describing: type(of: error)), privacy: .public)"
                )
            }
            await self?.finishNemotronPreparation(generation: generation, compiled: compiled)
            modelLease.release()
        }
    }

    private func finishNemotronPreparation(generation: UInt64, compiled: Bool) {
        let directory = locations.nemotronDiarizerDirectory
        if receipts[.nemotronDiarizer] == nil {
            // Deleted while compiling. The load may have fetched files back
            // before it noticed, unless a new install is putting them there.
            if !installing.contains(.nemotronDiarizer) {
                try? FileManager.default.removeItem(at: locations.containerDirectory(for: .nemotronDiarizer))
            }
        } else if compiled, Self.nemotron3FilesPresent(.offline, directory: directory) {
            let marker = directory.appendingPathComponent(Self.nemotron3CompileMarkerFile)
            try? Data((ModelNames.Nemotron3.weightsVersion + "\n").utf8).write(to: marker, options: .atomic)
        }
        guard nemotronPreparationGeneration == generation else { return }
        nemotronPreparation = nil
        onPreparationChange(false)
    }

    /// Stops the running preparation and drops its flag at once. The Core ML
    /// load inside it cannot be interrupted, so the task itself ends when that
    /// load returns, and cleans up after itself then.
    func cancelNemotronPreparation() {
        guard let running = nemotronPreparation, !running.isCancelled else { return }
        running.cancel()
        nemotronPreparationGeneration &+= 1
        onPreparationChange(false)
    }

    /// Returns when the background preparation, if one is running, has ended.
    public func waitForNemotronPreparation() async {
        await nemotronPreparation?.value
    }

    /// Diarizes one file with Nemotron 3, streamed from disk, so a file of any
    /// length fits in about the memory of a short one. Runs go through
    /// `nemotron3Runs`, one at a time: the actor lets a second call start while
    /// the first awaits its detached task, so the actor alone does not keep two
    /// meetings from holding two models at once.
    ///
    /// The application's `offline` preset must already be installed, and this
    /// throws `LocalModelError.notInstalled` rather than download it. The
    /// bench-only presets fetch on first use, so selecting one is the consent
    /// for its download.
    func nemotron3Diarize(
        audio: URL, preset: Nemotron3DiarizationBackend.Preset,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DiarizationOutput {
        try Task.checkCancellation()
        let modelLease = lease()
        defer { modelLease.release() }
        let root = locations.root
        await waitForNemotronPreparation()
        if preset == .offline,
            !Self.nemotron3FilesPresent(preset, directory: locations.nemotronDiarizerDirectory)
        {
            throw LocalModelError.notInstalled
        }
        return try await Self.nemotron3Runs.run {
            var provenance = Nemotron3DiarizationBackend.provenance(preset: preset)
            // Nothing is reported until audio flows through the model. A
            // fraction sent while the model loads would sit still for that
            // whole minute, which reads as stuck; the pipeline says the model
            // is loading instead.
            let silent = try Nemotron3DiarizationBackend.isEffectivelySilent(audio: audio).silent
            try Task.checkCancellation()
            guard !silent else {
                provenance["silentAudio"] = "true"
                progress(1)
                return DiarizationOutput(intervals: [], clusters: [], configuration: provenance)
            }
            let config = preset.configuration
            let models = try await Nemotron3Models.loadFromHuggingFace(
                config: config, cacheDirectory: root,
                computeUnits: LocalModelManager.nemotron3ComputeUnits
            )
            try Task.checkCancellation()
            // Cancellation is checked between blocks, so a cancelled job stops
            // within a few seconds of audio instead of finishing the file.
            let diarizer = Nemotron3Diarizer(config: config, models: models)
            let found = try Nemotron3DiarizationBackend.streamedSegments(
                audio: audio, diarizer: diarizer, progress: progress
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
