import FluidAudio
import Foundation
import PipitAudio
import PipitCore

/// On-device diarization with NVIDIA's Nemotron 3 Diarization model through
/// FluidAudio. Like LS-EEND it emits per-speaker activity frame by frame, so
/// two people talking at once stay two overlapping intervals; it tracks at
/// most eight speakers.
///
/// A benchmark candidate, reachable through `pipit-eval bench --diarizer
/// nemotron3` and constructed nowhere else until the comparative run says it
/// should be. It reports no embeddings; voice memory embeds its intervals with
/// the same extractor that covers the cloud diarizer.
public struct Nemotron3DiarizationBackend: DiarizationBackend {
    /// FluidAudio's presets that the bench puts under measurement. `offline`
    /// is the full-context preset; `fast128` trades accuracy headroom for
    /// speed and scored the same on the first five calls.
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
}

extension LocalModelManager {
    /// Diarizes one file with Nemotron 3. On the actor for the same reason
    /// every other local model pass is: one heavy job at a time.
    ///
    /// The model caches under the same root the other units live in, and
    /// arrives on first use of this backend: selecting `--diarizer nemotron3`
    /// is the consent for its download.
    func nemotron3Diarize(
        audio: URL, preset: Nemotron3DiarizationBackend.Preset,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DiarizationOutput {
        // The model is not Sendable, so its whole lifetime stays inside one
        // detached task and only the Sendable output crosses back.
        let root = locations.root
        return try await Task.detached(priority: .userInitiated) {
            let config = preset.configuration
            let models = try await Nemotron3Models.loadFromHuggingFace(
                config: config, cacheDirectory: root
            )
            let diarizer = Nemotron3Diarizer(config: config, models: models)
            let samples = try MonoAudioDecoder.loadMono16k(audio)
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
                configuration: [
                    "backend": Nemotron3DiarizationBackend.identifier(for: preset),
                    "pipeline": "nemotron3",
                    "variant": preset.rawValue,
                    "package": LocalSpeechStack.diarizerPackage,
                ]
            )
        }.value
    }
}
