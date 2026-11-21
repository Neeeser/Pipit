import Foundation

/// One case run under one configuration, as the harness writes it to `--out`.
///
/// It lives here rather than in the eval executable so a test can decode a
/// results file and the resume rule below can be pinned:
/// `scripts/build-bench-baselines.py` reads the same shape.
public struct BenchRow: Codable {
    public var engine: String
    public var diarizer: String
    public var score: BenchScore
    public var processingSeconds: Double
    public var audioSeconds: Double
    public var state: String
    public var transcriptionModels: [String]
    public var diarizationBackends: [String]
    /// What the truth records for the scored window, carried into the output
    /// so a row explains how hard its case was.
    public var overlapRatio: Double?
    /// Which run of `--repeats` this row is, from 1. Every run is written to
    /// `--out`, so the spread in the table can be checked against the rows it
    /// came from.
    public var run: Int = 1
    /// The meeting folder this row was scored from, when `--keep-scratch`
    /// preserved it.
    public var scratch: String?
    /// Which simulated call this row is and what the echo pass measured on it.
    /// Absent on a one-track case.
    public var call: BenchCallRow?
    /// How the meeting client's speaker record and the diarizer shared the far
    /// end (`pipit-eval bench --attribution`). Absent on rows written before it
    /// existed.
    public var sensorAttribution: String?
    /// Words on the far-end track, and how many of them sit under a speaker
    /// with no name.
    public var farEndWords: Int?
    public var unnamedFarEndWords: Int?
    /// The far-end words that can be checked against the reference speaker,
    /// split by whether the name on them is the right one, a wrong one or none.
    /// See `FarEndNameScore`. Present on a call case only.
    public var farEndNames: FarEndNameScore?
    /// How `score` grouped the transcript's lines into speakers: `display-name`
    /// puts lines under one speaker when the speaker map gives them one display
    /// name, as the app shows it, so two people sharing a name are one speaker.
    /// Rows without it grouped by speaker key, which counted a person split
    /// across keys once per key, and are not comparable on speaker count,
    /// cpWER or attribution where a case names its speakers.
    public var speakerGrouping: String?

    public init(
        engine: String, diarizer: String, score: BenchScore,
        processingSeconds: Double, audioSeconds: Double, state: String,
        transcriptionModels: [String], diarizationBackends: [String],
        overlapRatio: Double?, run: Int = 1, scratch: String? = nil, call: BenchCallRow? = nil
    ) {
        self.call = call
        self.engine = engine
        self.diarizer = diarizer
        self.score = score
        self.processingSeconds = processingSeconds
        self.audioSeconds = audioSeconds
        self.state = state
        self.transcriptionModels = transcriptionModels
        self.diarizationBackends = diarizationBackends
        self.overlapRatio = overlapRatio
        self.run = run
        self.scratch = scratch
    }
}

/// What a `--resume` invocation still owes for one case.
///
/// A row exists only if its run completed and was scored, so a run that
/// crashed or was interrupted is simply absent and comes back as pending. A
/// multi-hour engine survives a session timeout this way: relaunching with the
/// same `--out` re-runs only what is missing, and the recorded rows still feed
/// the deciding mean.
public enum BenchResume {
    public static func pending(
        existing: [BenchRow], meeting: String, engine: String, diarizer: String, repeats: Int
    ) -> (done: [BenchRow], runs: [Int]) {
        let done = existing.filter {
            $0.score.meeting == meeting && $0.engine == engine
                && $0.diarizer == diarizer && (1...max(1, repeats)).contains($0.run)
        }
        let recorded = Set(done.map(\.run))
        let runs = (1...max(1, repeats)).filter { !recorded.contains($0) }
        return (done, runs)
    }
}
