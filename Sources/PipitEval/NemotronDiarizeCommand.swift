import Foundation
import PipitAudio
import PipitCore
import PipitLocalAI

/// `pipit-eval diarize --diarizer nemotron3`: Nemotron alone on one file, with
/// no clusterer behind it, reporting run time and peak memory.
///
/// `--embed` then runs the voice-vector pass a meeting runs on Nemotron's
/// clusters, on their solo speech, and reports its time and memory too, since
/// that pass decodes the file again. `--json` writes the intervals, times and
/// cluster labels only, for scoring against a truth file.
enum NemotronDiarizeCommand {
    static func run(
        audio: URL, manager: LocalModelManager, preset: Nemotron3DiarizationBackend.Preset,
        embed: Bool, json: URL?
    ) async throws {
        _ = try await manager.install(units: [.diarizer, .nemotronDiarizer])
        let seconds = MonoAudioDecoder.durationSeconds(audio)
        print("file      \(audio.lastPathComponent)  \(String(format: "%.1f", seconds))s")
        let before = peakResidentBytes()

        let started = Date()
        let output = try await Nemotron3DiarizationBackend(models: manager, preset: preset)
            .diarize(audio: audio, progress: { _ in })
        let elapsed = Date().timeIntervalSince(started)
        let speech = output.intervals.reduce(0) { $0 + $1.duration }
        print(
            String(
                format: "nemotron  speakers %d  segments %d  speech %.0fs  %.1fs  RTFx %.1f",
                output.speakerCount, output.intervals.count, speech, elapsed,
                seconds / max(elapsed, 0.001)))
        print("          peak resident \(megabytes(peakResidentBytes())) (before \(megabytes(before)))")

        if embed {
            let solo = DiarizationInterval.soloSpeech(output.intervals)
            let embedStarted = Date()
            let vectors = try await FluidAudioEmbeddingExtractor(models: manager)
                .embed(audio: audio, intervals: solo)
            let embedElapsed = Date().timeIntervalSince(embedStarted)
            let clusters = Set(vectors.map(\.clusterID)).count
            print(
                String(
                    format: "embed     vectors %d for %d clusters  %.1fs",
                    vectors.count, clusters, embedElapsed))
            print("          peak resident \(megabytes(peakResidentBytes()))")
        }

        if let json {
            let intervals = output.intervals.map {
                ["start": $0.start, "end": $0.end, "clusterID": $0.clusterID] as [String: Any]
            }
            let data = try JSONSerialization.data(
                withJSONObject: ["seconds": seconds, "intervals": intervals], options: [.sortedKeys])
            try data.write(to: json)
        }
    }
}
