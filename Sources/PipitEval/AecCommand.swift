import Foundation
import PipitAudio
import PipitCore
import PipitServices

/// `pipit-eval aec`: the shipped echo pass over two audio files.
///
/// Takes a microphone recording and the far end that was played, writes the
/// cleaned microphone, and prints what the pass measured. The bake-off harness
/// runs it over public corpora so the canceller Pipit ships is scored the same
/// way as every candidate, and a port of the canceller is checked against a
/// stored output of this command.
enum AecCommand {
    struct Report: Codable {
        var microphone: String
        var reference: String
        var output: String
        var frames: Int64
        var referenceOffsetSeconds: Double
        var alignmentOffsetSeconds: Double
        var alignmentCorrelation: Double
        var alignmentUsable: Bool
        var farEndActiveWindows: Int
        var medianChangeDB: Double
        var reportedMedianDB: Double
        var decision: String
    }

    /// Which canceller to run, from `PIPIT_ECHO_STAGE`: `filter` or
    /// `network` for one stage of the shipped pass alone, anything else for
    /// the pass as shipped. A harness checks each stage against its own
    /// reference implementation this way.
    static func stage() throws -> any EchoCancelling {
        let rate = 16_000
        switch ProcessInfo.processInfo.environment["PIPIT_ECHO_STAGE"] {
        case "filter":
            let models = try EchoModels.modelDirectory()
            guard
                let filter = LocalVQECanceller(
                    model: models.appendingPathComponent(EchoModels.filterModel),
                    sampleRate: rate, filterOnlyLatency: true
                )
            else { throw EchoModels.ModelError.refused(EchoModels.filterModel) }
            return filter
        case "network":
            let models = try EchoModels.modelDirectory()
            return try DTLNCanceller(
                weights: DTLNCanceller.Weights(directory: models, name: EchoModels.networkModel)
            )
        default:
            return try EchoModels.shippedCanceller(sampleRate: rate)
        }
    }

    static func run(
        microphone: URL, reference: URL, output: URL, referenceOffset: Double?, json: URL?
    ) -> Int32 {
        let started = Date()
        let run: EchoCancellationPass.FileRun
        do {
            run = try EchoCancellationPass.clean(
                microphoneFile: microphone, referenceFile: reference,
                referenceOffset: referenceOffset, to: output, canceller: stage
            )
        } catch {
            note("aec: \(error)")
            return 1
        }
        let elapsed = Date().timeIntervalSince(started)
        let judgement = EchoCancellationPass.judge(windows: run.windows)
        let active = run.windows.filter { $0.farEndDBFS > EchoCancellationPass.farEndActiveDBFS }
        let changes = active.map { $0.microphoneBeforeDBFS - $0.microphoneAfterDBFS }
        let report = Report(
            microphone: microphone.lastPathComponent,
            reference: reference.lastPathComponent,
            output: output.path,
            frames: run.frames,
            referenceOffsetSeconds: run.referenceOffset,
            alignmentOffsetSeconds: run.alignment.offsetSeconds,
            alignmentCorrelation: run.alignment.correlation,
            alignmentUsable: run.alignment.isUsable,
            farEndActiveWindows: active.count,
            medianChangeDB: EchoCancellationPass.percentile(changes, 0.5) ?? 0,
            reportedMedianDB: judgement.reportedMedianDB,
            decision: judgement.outcome.rawValue
        )
        print("microphone      \(report.microphone)")
        print("reference       \(report.reference)")
        print("output          \(report.output)")
        print(
            "audio           \(String(format: "%.1f", Double(run.frames) / 16_000))s in"
                + " \(String(format: "%.1f", elapsed))s")
        print(
            "alignment       \(String(format: "%+.3f", report.alignmentOffsetSeconds))s at"
                + " \(String(format: "%.3f", report.alignmentCorrelation)),"
                + " \(report.alignmentUsable ? "used" : "not used")")
        print("offset used     \(String(format: "%+.3f", report.referenceOffsetSeconds))s")
        print("far end active  \(report.farEndActiveWindows) windows")
        print("median change   \(String(format: "%.1f", report.medianChangeDB)) dB")
        print("reported        \(String(format: "%.1f", report.reportedMedianDB)) dB")
        print("decision        \(report.decision)")
        if let json {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: json, options: .atomic)
            } catch {
                note("aec: could not write \(json.path): \(error)")
                return 1
            }
        }
        return 0
    }
}
