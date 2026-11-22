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
        /// A simulated meeting-client record, written for the variants that
        /// model a call with a sensor. It is a `RawSensors` file as stored.
        public var sensors: AudioFile?
    }

    public struct Echo: Codable, Sendable, Equatable {
        /// What the variant asked for, nil for a microphone with no echo.
        public var targetCorrelation: Double?
        /// What the generator's copy of Pipit's measure read on the finished
        /// microphone.
        public var correlation: Double
        public var reachedTarget: Bool
        /// Power of the echo against the local person's voice while they speak,
        /// in dB. Nil for a microphone with no echo, and in a description
        /// written before the generator recorded it.
        public var echoToLocalVoiceDB: Double?
    }

    /// How the far-end file was made to disagree with the microphone in time.
    public struct FarEnd: Codable, Sendable, Equatable {
        /// How long after the microphone the far-end file begins. The bench
        /// imports it at that start time, as a capture stamps a late track.
        public var startSeconds: Double
        /// Far-end audio removed with nothing in its place, which moves the
        /// rest of the track earlier against the microphone by this much.
        public var lostSeconds: Double
    }

    public var `case`: String
    public var meeting: String
    public var variant: String
    /// The annotation agent and the reference speaker who play the local person.
    public var localAgent: String
    public var localSpeaker: String
    public var files: Files
    public var echo: Echo
    /// Nil when the two tracks are aligned to the sample.
    public var farEnd: FarEnd?

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
    /// How loud the echo is against the local person's voice, in dB, nil with
    /// no echo.
    public var echoToLocalVoiceDB: Double?
    /// True when the case carries a simulated meeting-client record, so a
    /// reader knows its speaker evidence came from chosen timing numbers.
    public var simulatedSensors: Bool
    /// What the pipeline's own cleaner stored as `cleanedMic.echoCorrelationBefore`.
    /// Nil when the cleaner kept the microphone as recorded, which it does when
    /// it finds too little echo to remove.
    public var echoCorrelationBefore: Double?
    public var echoRemovedMedianDB: Double?
    /// The cleaner's decision for this call.
    public var cleaningOutcome: String?

    public init(
        variant: String, localSpeaker: String, targetEchoCorrelation: Double?,
        generatedEchoCorrelation: Double, echoToLocalVoiceDB: Double?, simulatedSensors: Bool,
        echoCorrelationBefore: Double?, echoRemovedMedianDB: Double?, cleaningOutcome: String?
    ) {
        self.variant = variant
        self.localSpeaker = localSpeaker
        self.targetEchoCorrelation = targetEchoCorrelation
        self.generatedEchoCorrelation = generatedEchoCorrelation
        self.echoToLocalVoiceDB = echoToLocalVoiceDB
        self.simulatedSensors = simulatedSensors
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
    /// - A lost word is a reference word of the local person that no transcript
    ///   word accounts for. A transcript word accounts for one reference word at
    ///   most: it has the same text, starts within three seconds, and carries
    ///   any label. Without that pairing one "yeah" in the transcript would
    ///   cover every "yeah" the local person said in the same six seconds.
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
        let found = localStarts.reduce(0) { total, entry in
            total + pairedCount(of: entry.value, with: anyStarts[entry.key] ?? [])
        }
        let lost = local.count - found
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

    /// How many of `reference` start times can each take a different time from
    /// `candidates` within the window. Both lists are sorted. Taking the
    /// earliest unused candidate that is in range for each reference time, in
    /// order, gives the largest possible pairing when every window is the same
    /// width.
    static func pairedCount(of reference: [Double], with candidates: [Double]) -> Int {
        var next = 0
        var paired = 0
        for time in reference {
            while next < candidates.count, candidates[next] < time - localTrackWindow { next += 1 }
            if next < candidates.count, candidates[next] <= time + localTrackWindow {
                paired += 1
                next += 1
            }
        }
        return paired
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

/// A far-end line of a transcript with the display name a reader sees on it.
public struct NamedUtterance: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    /// The speaker's display name, or nil where the line has none.
    public var name: String?

    public init(start: Double, end: Double, text: String, name: String?) {
        self.start = start
        self.end = end
        self.text = text
        self.name = name
    }
}

/// How the far end's words fared on naming, on the words that can be checked.
///
/// The checked words are the content words of the transcript that match a
/// reference word of a far-end speaker within three seconds. Short and function
/// words are skipped because several speakers say them at the same moment.
public struct FarEndNameScore: Codable, Sendable, Equatable {
    /// Under the display name of the reference speaker who said them.
    public var right: Int
    /// Under a different name.
    public var wrong: Int
    /// Under no name.
    public var unnamed: Int

    public init(right: Int, wrong: Int, unnamed: Int) {
        self.right = right
        self.wrong = wrong
        self.unnamed = unnamed
    }
}

extension BenchScorer {
    /// Compares the name on each far-end word with the name of the reference
    /// speaker who said it.
    ///
    /// A simulated call names a participant after the reference speaker, so the
    /// two names are equal where the transcript is right. The reference speaker
    /// of a word is the one whose same word lies nearest in time, within three
    /// seconds, among the far-end speakers. An utterance's words are spread
    /// evenly across its span, as the other scores do.
    public static func farEndNames(
        truth: BenchTruth, utterances: [NamedUtterance], localSpeaker: String
    ) -> FarEndNameScore {
        var byText: [String: [(start: Double, speaker: String)]] = [:]
        for (speaker, tokens) in referenceSpeakerStreams(truth) where speaker != localSpeaker {
            for token in tokens { byText[token.text, default: []].append((token.start, speaker)) }
        }
        let sorted = byText.mapValues { $0.sorted { $0.start < $1.start } }

        var score = FarEndNameScore(right: 0, wrong: 0, unnamed: 0)
        for utterance in utterances {
            let parts = normalise(utterance.text)
            guard !parts.isEmpty else { continue }
            let width = max(0, utterance.end - utterance.start) / Double(parts.count)
            let name = (utterance.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            for (index, part) in parts.enumerated() {
                if leakIgnored.contains(part) || part.count < 3 { continue }
                guard let times = sorted[part] else { continue }
                let start = utterance.start + Double(index) * width
                guard let speaker = nearest(to: start, in: times) else { continue }
                if name.isEmpty {
                    score.unnamed += 1
                } else if name == speaker {
                    score.right += 1
                } else {
                    score.wrong += 1
                }
            }
        }
        return score
    }

    /// The speaker of the entry closest to `time`, within the window.
    private static func nearest(
        to time: Double, in entries: [(start: Double, speaker: String)]
    ) -> String? {
        var low = 0
        var high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].start < time { low = middle + 1 } else { high = middle }
        }
        var best: (gap: Double, speaker: String)?
        for index in [low - 1, low] where entries.indices.contains(index) {
            let gap = abs(entries[index].start - time)
            if gap <= localTrackWindow, best.map({ gap < $0.gap }) ?? true {
                best = (gap, entries[index].speaker)
            }
        }
        return best?.speaker
    }
}
