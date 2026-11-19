import Foundation

/// One simulated call, as `Benchmarks/calls/generate.py` describes it in the
/// `case.json` beside the two tracks it wrote.
///
/// The generator picks the local person from the manifest's seed and records
/// the choice here, so the harness never repeats that arithmetic.
public struct BenchCallCase: Codable, Sendable, Equatable {
    public struct AudioFile: Codable, Sendable, Equatable {
        public var name: String
        public var sha256: String
    }

    public struct Files: Codable, Sendable, Equatable {
        public var mic: AudioFile
        public var remote: AudioFile
    }

    public struct Echo: Codable, Sendable, Equatable {
        /// What the variant asked for, nil for a microphone with no echo.
        public var targetCorrelation: Double?
        /// What the generator's copy of Pipit's measure read on the finished
        /// microphone.
        public var correlation: Double
        public var reachedTarget: Bool
    }

    public var `case`: String
    public var meeting: String
    public var variant: String
    /// The annotation agent and the reference speaker who play the local person.
    public var localAgent: String
    public var localSpeaker: String
    public var files: Files
    public var echo: Echo

    public static func read(from url: URL) throws -> BenchCallCase {
        try JSONDecoder().decode(BenchCallCase.self, from: Data(contentsOf: url))
    }
}

/// What a call row records beyond the transcript scores: which simulated call
/// it was, and what Pipit itself measured while cleaning the microphone.
public struct BenchCallRow: Codable, Sendable, Equatable {
    public var variant: String
    public var localSpeaker: String
    /// The correlation the variant was built to read, nil with no echo.
    public var targetEchoCorrelation: Double?
    /// What the generator measured on the finished microphone.
    public var generatedEchoCorrelation: Double
    /// What the pipeline's own cleaner stored as `cleanedMic.echoCorrelationBefore`.
    /// Nil when the cleaner kept the microphone as recorded, which it does when
    /// it finds too little echo to remove.
    public var echoCorrelationBefore: Double?
    public var echoRemovedMedianDB: Double?
    /// The cleaner's decision for this call.
    public var cleaningOutcome: String?

    public init(
        variant: String, localSpeaker: String, targetEchoCorrelation: Double?,
        generatedEchoCorrelation: Double, echoCorrelationBefore: Double?,
        echoRemovedMedianDB: Double?, cleaningOutcome: String?
    ) {
        self.variant = variant
        self.localSpeaker = localSpeaker
        self.targetEchoCorrelation = targetEchoCorrelation
        self.generatedEchoCorrelation = generatedEchoCorrelation
        self.echoCorrelationBefore = echoCorrelationBefore
        self.echoRemovedMedianDB = echoRemovedMedianDB
        self.cleaningOutcome = cleaningOutcome
    }
}

/// How a two-track call treated the person holding the microphone.
///
/// Two failures matter to someone reading a transcript of a call they took on
/// laptop speakers: other people's words appearing under their own name, and
/// their own words going missing. Both are counted per minute of the scored
/// window so a long call and a short one read on one scale.
public struct LocalTrackScore: Codable, Sendable, Equatable {
    public var localSpeaker: String
    public var localKey: String
    /// Reference words the local person said, and everyone else's.
    public var localWords: Int
    public var farEndWords: Int
    /// Words labelled as the local person that the far end said at that moment
    /// and the local person did not.
    public var farEndWordsUnderLocal: Int
    /// The local person's words that no part of the transcript holds.
    public var localWordsLost: Int
    public var farEndWordsUnderLocalPerMinute: Double
    public var localWordsLostPerMinute: Double
}

extension BenchScorer {
    /// How close in time two occurrences of a word must be to count as the same
    /// utterance of it. Matches the window `Benchmarks/aec/metrics.py` uses.
    static let localTrackWindow = 3.0

    /// Words the far end and the local person both say all the time, so a
    /// match on one of them proves nothing about whose voice it was.
    static let leakIgnored: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "it", "is", "i", "you", "we",
        "so", "uh", "um", "yeah", "okay", "ok", "yes", "no", "like", "that", "this",
    ]

    /// The two local-track numbers. The definitions mirror
    /// `Benchmarks/aec/metrics.py`:
    ///
    /// - A far-end word under the local person is a transcript word labelled
    ///   `localKey` that matches a far-end reference word within three seconds
    ///   and matches none of the local person's own. Short and function words
    ///   are skipped because both sides say them.
    /// - A lost word is a reference word of the local person that matches no
    ///   transcript word within three seconds, under any label.
    ///
    /// The local key is known by construction, so this does not depend on the
    /// speaker mapping the other scores use.
    public static func localTrack(
        truth: BenchTruth, utterances: [BenchUtterance], localSpeaker: String, localKey: String
    ) -> LocalTrackScore {
        let reference = referenceSpeakerStreams(truth)
        let local = reference[localSpeaker] ?? []
        let far = reference.filter { $0.key != localSpeaker }.values.flatMap { $0 }
        let hypothesis = hypothesisSpeakerStreams(utterances)

        let localStarts = startsByText(local)
        let farStarts = startsByText(far)
        let anyStarts = startsByText(hypothesis.values.flatMap { $0 })

        var leaked = 0
        for token in hypothesis[localKey] ?? [] {
            if leakIgnored.contains(token.text) || token.text.count < 3 { continue }
            if hasNear(token, in: farStarts) && !hasNear(token, in: localStarts) { leaked += 1 }
        }
        let lost = local.filter { !hasNear($0, in: anyStarts) }.count
        let minutes = max(truth.windowSeconds / 60, 1.0 / 60)
        return LocalTrackScore(
            localSpeaker: localSpeaker, localKey: localKey,
            localWords: local.count, farEndWords: far.count,
            farEndWordsUnderLocal: leaked, localWordsLost: lost,
            farEndWordsUnderLocalPerMinute: (Double(leaked) / minutes * 100).rounded() / 100,
            localWordsLostPerMinute: (Double(lost) / minutes * 100).rounded() / 100
        )
    }

    /// Start times of each distinct word, sorted, for a window search.
    private static func startsByText(_ tokens: [TimedToken]) -> [String: [Double]] {
        var starts: [String: [Double]] = [:]
        for token in tokens { starts[token.text, default: []].append(token.start) }
        return starts.mapValues { $0.sorted() }
    }

    private static func hasNear(_ token: TimedToken, in starts: [String: [Double]]) -> Bool {
        guard let times = starts[token.text] else { return false }
        var low = 0
        var high = times.count
        while low < high {
            let middle = (low + high) / 2
            if times[middle] < token.start - localTrackWindow { low = middle + 1 } else { high = middle }
        }
        return low < times.count && times[low] <= token.start + localTrackWindow
    }
}
