import Foundation
import PipitBench
import Testing

/// Controls on the meter itself.
///
/// A benchmark number is only worth reading if the scorer is known to be right,
/// so three transcripts with known answers are put through it: the reference
/// itself, the reference with one word in ten deleted, and the reference with
/// its speaker labels shuffled. The first two pin word error rate to an exact
/// value; the third pins attribution and DER to chance, which is what a
/// diarizer that has learned nothing scores.
@Suite("BenchScorer")
struct BenchScorerTests {
    /// The committed truth for one AMI excerpt, which is text and already in
    /// the tree for the harness to score against.
    private static func truth() throws -> BenchTruth {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PipitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()
        return try BenchTruth.read(
            from: repository.appendingPathComponent("Benchmarks/ground-truth/ES2002b.json")
        )
    }

    /// A score holding only the fields a baseline rule reads. Decoded rather
    /// than built, because the memberwise initialiser is internal to the bench
    /// module.
    private static func score(
        werNoFiller: Double, attribution: Double, repeats: Int, tcpWer: Double? = nil
    ) throws -> BenchScore {
        let json = """
            {"meeting":"ES2002b","wer":\(werNoFiller),"werNoFiller":\(werNoFiller),
             \(tcpWer.map { "\"tcpWer\":\($0)," } ?? "")
             "substitutions":0,"insertions":0,"deletions":0,"referenceWords":100,
             "hypothesisWords":100,"utterances":10,"attribution":\(attribution),
             "attributionMerged":\(attribution),"attributionOfLabelled":\(attribution),
             "attributionScored":100,"overlapExcluded":0,"referenceSpeakers":4,
             "hypothesisSpeakers":4,"speakerKeys":[],"clusterMapping":{},
             "repeatedNgrams":\(repeats),"repeatedShare":0,"overlappingPairs":0,
             "worstOverlapSeconds":0,"werConversational":\(werNoFiller),
             "orderingFloorWer":0,"attributionCoverage":1,
             "speechCoverage":0.9,"wordsPerMinute":150}
            """
        return try JSONDecoder().decode(BenchScore.self, from: Data(json.utf8))
    }

    /// One run of a case, with the fields the deciding aggregation touches and
    /// two it must leave alone: `deletions` counts a particular transcript and
    /// `clusterMapping` describes a particular set of clusters.
    private static func run(
        wer: Double, attribution: Double, der: Double?, repeats: Int, deletions: Int
    ) throws -> BenchScore {
        let json = """
            {"meeting":"ES2002b","wer":\(wer),"werNoFiller":\(wer / 2),
             "werConversational":\(wer / 4),"orderingFloorWer":0.1,
             "substitutions":0,"insertions":0,"deletions":\(deletions),
             "referenceWords":100,"hypothesisWords":100,"utterances":10,
             "attribution":\(attribution),"attributionMerged":\(attribution + 0.05),
             "attributionOfLabelled":\(attribution + 0.02),"attributionScored":100,
             "overlapExcluded":0,"attributionCoverage":1,"referenceSpeakers":4,
             "hypothesisSpeakers":4,"speakerKeys":["c\(deletions)"],
             "clusterMapping":{"c\(deletions)":"A"},"repeatedNgrams":\(repeats),
             "repeatedShare":0,"overlappingPairs":0,"worstOverlapSeconds":0,
             \(der.map { "\"der\":\($0),\"derStrict\":\($0 + 0.1)," } ?? "")
             "speechCoverage":0.9,"wordsPerMinute":150}
            """
        return try JSONDecoder().decode(BenchScore.self, from: Data(json.utf8))
    }

    /// The transcript a perfect system would produce: one line per reference
    /// turn, holding that turn's words, under an opaque cluster key.
    ///
    /// The keys are `c0`...`c3` rather than the reference names, so the scorer
    /// has the permutation to solve that a real diarizer hands it.
    private static func oracle(_ truth: BenchTruth) -> [BenchUtterance] {
        let key = Dictionary(uniqueKeysWithValues: truth.speakers.enumerated().map {
            ($0.element, "c\($0.offset)")
        })
        var bySpeaker: [String: [BenchTruth.Word]] = [:]
        for word in truth.words { bySpeaker[word.speaker, default: []].append(word) }
        for key in bySpeaker.keys { bySpeaker[key]?.sort { $0.start < $1.start } }
        return truth.turns.sorted { $0.start < $1.start }.map { turn in
            let inside = (bySpeaker[turn.speaker] ?? []).filter {
                $0.start >= turn.start - 0.001 && $0.end <= turn.end + 0.001
            }
            return BenchUtterance(
                start: turn.start, end: turn.end,
                text: inside.map(\.text).joined(separator: " "),
                speakerKey: key[turn.speaker] ?? turn.speaker
            )
        }
    }

    /// Deterministic, because a control that draws differently every run is not
    /// a control. Any fixed sequence does; this is the smallest one.
    private struct FixedSequence {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        mutating func next(upTo bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    /// Four speakers with one turn each, two of them split across two clusters.
    ///
    /// Hand-computable: 200 words per speaker, and the diarizer cuts A's turn
    /// into 120 words on c0 and 80 on c4, B's into 120 on c1 and 80 on c5.
    private static func splitCase() -> (truth: BenchTruth, utterances: [BenchUtterance]) {
        let speakers = ["A", "B", "C", "D"]
        var words: [BenchTruth.Word] = []
        var turns: [BenchTruth.Turn] = []
        for (index, speaker) in speakers.enumerated() {
            let base = Double(index) * 100
            turns.append(BenchTruth.Turn(speaker: speaker, start: base, end: base + 100))
            for step in 0..<200 {
                let start = base + Double(step) * 0.5
                words.append(BenchTruth.Word(
                    start: start, end: start + 0.4,
                    text: "\(speaker)\(step)", speaker: speaker, truncated: false
                ))
            }
        }
        let utterances = [
            BenchUtterance(start: 0, end: 60, text: "a", speakerKey: "c0"),
            BenchUtterance(start: 60, end: 100, text: "b", speakerKey: "c4"),
            BenchUtterance(start: 100, end: 160, text: "c", speakerKey: "c1"),
            BenchUtterance(start: 160, end: 200, text: "d", speakerKey: "c5"),
            BenchUtterance(start: 200, end: 300, text: "e", speakerKey: "c2"),
            BenchUtterance(start: 300, end: 400, text: "f", speakerKey: "c3"),
        ]
        let truth = BenchTruth(
            meeting: "split", source: "none.wav", windowStart: nil, windowSeconds: 400,
            speakers: speakers, agentToSpeaker: [:], words: words, turns: turns
        )
        return (truth, utterances)
    }

    /// A truth built from turns, each holding evenly spaced one-second words.
    private static func made(
        _ turns: [(speaker: String, start: Double, words: [String])], seconds: Double
    ) -> BenchTruth {
        var words: [BenchTruth.Word] = []
        var spans: [BenchTruth.Turn] = []
        for turn in turns {
            for (step, text) in turn.words.enumerated() {
                let start = turn.start + Double(step)
                words.append(BenchTruth.Word(
                    start: start, end: start + 0.5, text: text,
                    speaker: turn.speaker, truncated: false
                ))
            }
            spans.append(BenchTruth.Turn(
                speaker: turn.speaker, start: turn.start,
                end: turn.start + Double(turn.words.count)
            ))
        }
        return BenchTruth(
            meeting: "made", source: "none.wav", windowStart: nil, windowSeconds: seconds,
            speakers: Array(Set(turns.map(\.speaker))).sorted(), agentToSpeaker: [:],
            words: words, turns: spans
        )
    }

    /// Eight clusters, four speakers, ten words each: every count ties.
    private static func tiesCase() -> (
        pairs: [(reference: String, hypothesis: String?)], speakers: [String], keys: [String]
    ) {
        let speakers = ["A", "B", "C", "D"]
        var pairs: [(reference: String, hypothesis: String?)] = []
        for (index, key) in (0..<8).map({ ("c\($0)") }).enumerated() {
            let speaker = speakers[index / 2]
            for _ in 0..<10 { pairs.append((speaker, key)) }
        }
        return (pairs, speakers, (0..<8).map { "c\($0)" })
    }

    /// The repository root, three directories above this file.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("the reference scored against itself is a perfect transcript")
    func theReferenceScoredAgainstItselfIsAPerfectTranscript() async throws {
        let truth = try Self.truth()
        let score = BenchScorer.score(truth: truth, utterances: Self.oracle(truth))
        #expect(
            abs(score.wer - 0) <= 0.0001,
            "expected \(0) ± \(0.0001), got \(score.wer) — an oracle transcript has no errors"
        )
        #expect(abs(score.attribution - 1.0) <= 0.001, "expected \(1.0) ± \(0.001), got \(score.attribution)")
        let der = try #require(score.der)
        #expect(abs(der - 0) <= 0.0001, "expected \(0) ± \(0.0001), got \(der)")
        #expect(score.repeatedNgrams == 0)
        #expect(score.hypothesisSpeakers == truth.speakers.count)
    }

    @Test("deleting one word in ten costs ten points of word error rate")
    func deletingOneWordInTenCostsTenPointsOfWordErrorRate() async throws {
        let truth = try Self.truth()
        var kept = 0
        let thinned = Self.oracle(truth).map { utterance -> BenchUtterance in
            var words: [String] = []
            for word in utterance.text.split(separator: " ") {
                kept += 1
                if kept % 10 != 0 { words.append(String(word)) }
            }
            var copy = utterance
            copy.text = words.joined(separator: " ")
            return copy
        }
        let score = BenchScorer.score(truth: truth, utterances: thinned)
        #expect(
            abs(score.wer - 0.101) <= 0.005,
            "expected \(0.101) ± \(0.005), got \(score.wer) — one word in ten deleted is a tenth of the reference"
        )
        #expect(score.insertions == 0, "deleting words cannot produce an insertion")
    }

    @Test("shuffled speaker labels score at chance")
    func shuffledSpeakerLabelsScoreAtChance() async throws {
        let truth = try Self.truth()
        var sequence = FixedSequence()
        let keys = (0..<truth.speakers.count).map { "c\($0)" }
        let shuffled = Self.oracle(truth).map { utterance -> BenchUtterance in
            var copy = utterance
            copy.speakerKey = keys[sequence.next(upTo: keys.count)]
            return copy
        }
        let score = BenchScorer.score(truth: truth, utterances: shuffled)
        // The words are untouched, so only the labels are being measured.
        #expect(abs(score.wer - 0) <= 0.0001, "expected \(0) ± \(0.0001), got \(score.wer)")
        // The optimal cluster mapping lifts a random assignment above
        // the one-in-four a coin toss suggests, and the Python
        // reference measured 49% attribution and 46.5% DER on this
        // excerpt. A real run scores 99% and 8%, so the band is wide
        // and still tells the two apart.
        #expect(
            score.attribution > 0.30 && score.attribution < 0.65,
            "random labels scored \(score.attribution) attribution"
        )
        let der = try #require(score.der)
        #expect(der > 0.25 && der < 0.70, "random labels scored \(der) DER")
    }

    @Test("an over-split transcript scores strict below merged")
    func anOverSplitTranscriptScoresStrictBelowMerged() async throws {
        // Four speakers, one turn each, 200 words each. Two of those
        // turns are cut in half by the diarizer, so six clusters cover
        // four voices and 800 words are attributed.
        let split = Self.splitCase()
        let score = BenchScorer.score(truth: split.truth, utterances: split.utterances)
        #expect(score.attributionScored == 800, "every word is asked about")
        #expect(score.hypothesisSpeakers == 6)
        // The four clusters of the best injective mapping hold
        // 120 + 120 + 200 + 200 = 640 words.
        #expect(abs(score.attribution - 0.8) <= 0.0001, "expected \(0.8) ± \(0.0001), got \(score.attribution)")
        // Folding c4 onto A and c5 onto B recovers the other 160.
        #expect(
            abs(score.attributionMerged - 1.0) <= 0.0001,
            "expected \(1.0) ± \(0.0001), got \(score.attributionMerged)"
        )
        #expect(
            abs(score.attributionOfLabelled - 0.8) <= 0.0001,
            "expected \(0.8) ± \(0.0001), got \(score.attributionOfLabelled)"
        )
    }

    @Test("interleaved speech costs an oracle transcript word order")
    func interleavedSpeechCostsAnOracleTranscriptWordOrder() async throws {
        // One long turn with a backchannel dropped into the middle of
        // it. Read by turn the reference ends "five yeah"; read by the
        // clock the "yeah" falls between "four" and "five", so a
        // transcript that gets every word right still pays two edits,
        // which the DP takes as two substitutions over that pair.
        let interleaved = Self.made([
            ("A", 0, ["one", "two", "three", "four", "five"]),
            ("B", 3.5, ["yeah"]),
        ], seconds: 10)
        #expect(
            abs(BenchScorer.orderingFloor(interleaved) - (2.0 / 6.0)) <= 0.0001,
            "expected \(2.0 / 6.0) ± \(0.0001), got \(BenchScorer.orderingFloor(interleaved)) — one interleaved word costs two edits out of six words"
        )

        let sequential = Self.made([
            ("A", 0, ["one", "two", "three"]),
            ("B", 4, ["four", "five", "six"]),
            ("A", 8, ["seven", "eight"]),
        ], seconds: 12)
        #expect(
            abs(BenchScorer.orderingFloor(sequential) - 0) <= 0.0001,
            "expected \(0) ± \(0.0001), got \(BenchScorer.orderingFloor(sequential)) — turns that do not interleave read the same both ways"
        )

        // The floor comes off wer and never takes it below zero.
        let score = BenchScorer.score(
            truth: sequential,
            utterances: [BenchUtterance(
                start: 0, end: 12, text: "one two three four five six seven eight",
                speakerKey: "c0"
            )]
        )
        #expect(
            abs(score.orderingFloorWer - 0) <= 0.0001,
            "expected \(0) ± \(0.0001), got \(score.orderingFloorWer)"
        )
        #expect(
            abs(score.netOfFloorWer - score.wer) <= 0.0001,
            "expected \(score.wer) ± \(0.0001), got \(score.netOfFloorWer)"
        )
    }

    @Test("an oracle transcript scores zero per-speaker word error")
    func anOracleTranscriptScoresZeroPerSpeakerWordError() async throws {
        let truth = try Self.truth()
        let score = BenchScorer.score(truth: truth, utterances: Self.oracle(truth))
        let cpWer = try #require(score.cpWer)
        #expect(
            abs(cpWer - 0) <= 0.0001,
            "expected \(0) ± \(0.0001), got \(cpWer) — every speaker's words are present on some key, so the best assignment is exact"
        )
    }

    @Test("words on the wrong speaker are charged on both speakers' streams")
    func wordsOnTheWrongSpeakerAreChargedOnBothSpeakersStreams() async throws {
        // A and B speak four words each; the transcript holds all eight
        // words, all on one key. Serialized WER reads it as perfect.
        // Per speaker, A's stream carries four insertions and B's four
        // deletions: eight edits over eight reference words.
        let truth = Self.made([
            ("A", 0, ["a1", "a2", "a3", "a4"]),
            ("B", 4, ["b1", "b2", "b3", "b4"]),
        ], seconds: 10)
        let score = BenchScorer.score(
            truth: truth,
            utterances: [BenchUtterance(
                start: 0, end: 8, text: "a1 a2 a3 a4 b1 b2 b3 b4", speakerKey: "c0"
            )]
        )
        #expect(
            abs(score.wer - 0) <= 0.0001,
            "expected \(0) ± \(0.0001), got \(score.wer) — the serialized stream is exact"
        )
        let cpWer = try #require(score.cpWer)
        #expect(
            abs(cpWer - 1.0) <= 0.0001,
            "expected \(1.0) ± \(0.0001), got \(cpWer) — one stream for two speakers pays every misplaced word twice"
        )
    }

    @Test("a dropped overlap word is a deletion to cpWER and invisible to attribution")
    func aDroppedOverlapWordIsADeletionToCpWERAndInvisibleToAttribution() async throws {
        // The same sixteen-word fixture attribution coverage uses: the
        // last eight words are spoken across each other and the
        // transcript never writes B's overlapped four. Attribution
        // scores the easy half and says so; cpWER charges the four
        // missing words as deletions on B's stream.
        let truth = Self.made([
            ("A", 0, ["a1", "a2", "a3", "a4"]),
            ("B", 4, ["b1", "b2", "b3", "b4"]),
            ("A", 8, ["a5", "a6", "a7", "a8"]),
            ("B", 8, ["b5", "b6", "b7", "b8"]),
        ], seconds: 12)
        let score = BenchScorer.score(
            truth: truth,
            utterances: [
                BenchUtterance(start: 0, end: 4, text: "a1 a2 a3 a4", speakerKey: "c0"),
                BenchUtterance(start: 4, end: 8, text: "b1 b2 b3 b4", speakerKey: "c1"),
                BenchUtterance(start: 8, end: 12, text: "a5 a6 a7 a8", speakerKey: "c0"),
            ]
        )
        #expect(
            abs(score.attribution - 1.0) <= 0.0001,
            "expected \(1.0) ± \(0.0001), got \(score.attribution)"
        )
        let cpWer = try #require(score.cpWer)
        #expect(
            abs(cpWer - (4.0 / 16.0)) <= 0.0001,
            "expected \(4.0 / 16.0) ± \(0.0001), got \(cpWer) — the four overlapped words nobody transcribed are deletions"
        )
    }

    @Test("tcpWER charges words placed far from when they were spoken")
    func tcpWERChargesWordsPlacedFarFromWhenTheyWereSpoken() async throws {
        // The right words on the right speaker, twenty seconds late.
        // cpWER accepts them; the time-constrained variant refuses the
        // match beyond the five-second collar and pays each word as a
        // deletion where it was said plus an insertion where it landed.
        let truth = Self.made([("A", 0, ["a1", "a2", "a3", "a4"])], seconds: 30)
        let late = BenchScorer.score(
            truth: truth,
            utterances: [BenchUtterance(
                start: 20, end: 24, text: "a1 a2 a3 a4", speakerKey: "c0"
            )]
        )
        let lateCpWer = try #require(late.cpWer)
        #expect(abs(lateCpWer - 0) <= 0.0001, "expected \(0) ± \(0.0001), got \(lateCpWer)")
        let lateTcpWer = try #require(late.tcpWer)
        #expect(
            abs(lateTcpWer - 2.0) <= 0.0001,
            "expected \(2.0) ± \(0.0001), got \(lateTcpWer) — four deletions and four insertions over four reference words"
        )

        let punctual = BenchScorer.score(
            truth: truth,
            utterances: [BenchUtterance(
                start: 0, end: 4, text: "a1 a2 a3 a4", speakerKey: "c0"
            )]
        )
        let punctualTcpWer = try #require(punctual.tcpWer)
        #expect(
            abs(punctualTcpWer - 0) <= 0.0001,
            "expected \(0) ± \(0.0001), got \(punctualTcpWer)"
        )
    }

    @Test("attribution reports the share of words it asked about")
    func attributionReportsTheShareOfWordsItAskedAbout() async throws {
        // Sixteen words. The first eight are spoken alone, the last
        // eight across each other, so attribution is asked about half
        // the meeting and says so.
        let truth = Self.made([
            ("A", 0, ["a1", "a2", "a3", "a4"]),
            ("B", 4, ["b1", "b2", "b3", "b4"]),
            ("A", 8, ["a5", "a6", "a7", "a8"]),
            ("B", 8, ["b5", "b6", "b7", "b8"]),
        ], seconds: 12)
        let score = BenchScorer.score(
            truth: truth,
            utterances: [
                BenchUtterance(start: 0, end: 4, text: "a1 a2 a3 a4", speakerKey: "c0"),
                BenchUtterance(start: 4, end: 8, text: "b1 b2 b3 b4", speakerKey: "c1"),
                BenchUtterance(start: 8, end: 12, text: "a5 a6 a7 a8", speakerKey: "c0"),
            ]
        )
        #expect(score.overlapExcluded == 8, "the overlapping half is not asked")
        #expect(score.attributionScored == 8)
        #expect(
            abs(score.attributionCoverage - 0.5) <= 0.0001,
            "expected \(0.5) ± \(0.0001), got \(score.attributionCoverage) — half the reference words reached the question"
        )
        #expect(
            abs(score.attribution - 1.0) <= 0.0001,
            "expected \(1.0) ± \(0.0001), got \(score.attribution)"
        )
    }

    @Test("the conversational variant drops backchannels and the plain one does not")
    func theConversationalVariantDropsBackchannelsAndThePlainOneDoesNot() async throws {
        // "um" is hesitation, "okay" is a backchannel, and an engine
        // that writes neither is charged for one, both or nothing
        // depending on which number is read.
        let truth = Self.made([("A", 0, ["okay", "um", "the", "budget", "is", "fine"])], seconds: 8)
        let score = BenchScorer.score(
            truth: truth,
            utterances: [BenchUtterance(
                start: 0, end: 6, text: "the budget is fine", speakerKey: "c0"
            )]
        )
        #expect(
            abs(score.wer - (2.0 / 6.0)) <= 0.0001,
            "expected \(2.0 / 6.0) ± \(0.0001), got \(score.wer) — both are missing words"
        )
        #expect(
            abs(score.werNoFiller - (1.0 / 5.0)) <= 0.0001,
            "expected \(1.0 / 5.0) ± \(0.0001), got \(score.werNoFiller) — the filler set covers um and leaves okay charged"
        )
        #expect(
            abs(score.werConversational - 0) <= 0.0001,
            "expected \(0) ± \(0.0001), got \(score.werConversational) — the backchannel set covers okay as well"
        )
    }

    @Test("DER is reported under both mappings")
    func derIsReportedUnderBothMappings() async throws {
        // Six clusters over four speakers. Merged folds the two extra
        // clusters onto the voices they cover and scores clean; strict
        // leaves them holding their own keys, which is the last 40
        // seconds of A's turn and of B's, 80 of 400 seconds.
        let split = Self.splitCase()
        let score = BenchScorer.score(truth: split.truth, utterances: split.utterances)
        let merged = try #require(score.der)
        let strict = try #require(score.derStrict)
        #expect(
            abs(merged - 0) <= 0.01,
            "expected \(0) ± \(0.01), got \(merged) — the merged mapping covers every voice"
        )
        #expect(
            abs(strict - 0.2) <= 0.01,
            "expected \(0.2) ± \(0.01), got \(strict) — the two leftover clusters are 80 of 400 seconds"
        )
    }

    @Test("a case reports how densely its window is spoken")
    func aCaseReportsHowDenselyItsWindowIsSpoken() async throws {
        // Eight seconds of speech in a twenty second window, twelve
        // words in it.
        let truth = Self.made([
            ("A", 0, ["a1", "a2", "a3", "a4"]),
            ("B", 6, ["b1", "b2", "b3", "b4"]),
            ("A", 6, ["a5", "a6", "a7", "a8"]),
        ], seconds: 20)
        let score = BenchScorer.score(
            truth: truth,
            utterances: [BenchUtterance(start: 0, end: 4, text: "a1", speakerKey: "c0")]
        )
        #expect(
            abs(score.speechCoverage - 0.4) <= 0.0001,
            "expected \(0.4) ± \(0.0001), got \(score.speechCoverage) — two speakers over the same four seconds are four seconds of speech"
        )
        #expect(
            abs(score.wordsPerMinute - 36) <= 0.01,
            "expected \(36) ± \(0.01), got \(score.wordsPerMinute)"
        )
    }

    @Test("the greedy branch decides its ties by name")
    func theGreedyBranchDecidesItsTiesByName() async throws {
        // Eight clusters over four speakers, ten words each, so every
        // count ties and only the tiebreakers decide the mapping.
        let ties = Self.tiesCase()
        var seen: [BenchScorer.Mapping] = []
        for _ in 0..<8 {
            seen.append(BenchScorer.bestMapping(
                pairs: ties.pairs, referenceSpeakers: ties.speakers,
                hypothesisKeys: ties.keys
            ))
        }
        let expected = ["c0": "A", "c2": "B", "c4": "C", "c6": "D"]
        for mapping in seen {
            #expect(
                mapping.injective == expected,
                "count desc, reference asc, hypothesis asc decides every tie"
            )
            #expect(mapping.strictCorrect == 40)
            #expect(mapping.mergedCorrect == 80)
        }
    }

    @Test("a case with no baseline entry fails when entries are required")
    func aCaseWithNoBaselineEntryFailsWhenEntriesAreRequired() async throws {
        let baselines = BenchBaselines(entries: [:])
        let clean = try Self.score(werNoFiller: 0.20, attribution: 0.95, repeats: 0)
        #expect(
            baselines.regressions(key: "parakeet/local/Bmr019", score: clean).isEmpty,
            "an exploratory run without an entry still passes"
        )
        let required = baselines.regressions(
            key: "parakeet/local/Bmr019", score: clean, requireEntry: true
        )
        #expect(
            required == ["no baseline entry for parakeet/local/Bmr019"],
            "a gate with a hole in it is not a gate"
        )
    }

    @Test("tcpWER drift past its tolerance is a regression")
    func tcpWERDriftPastItsToleranceIsARegression() async throws {
        let baselines = BenchBaselines(entries: [
            "parakeet/local/EN2002d": BenchBaselines.Entry(
                wer: 0.40, werNoFiller: 0.38, attribution: 0.85, der: 0.30,
                repeatedNgrams: 0, tcpWer: 0.45
            )
        ])
        let drifted = try Self.score(
            werNoFiller: 0.38, attribution: 0.85, repeats: 0, tcpWer: 0.50
        )
        #expect(
            baselines.regressions(key: "parakeet/local/EN2002d", score: drifted)
                == ["tcpWER 50.0% against 45.0%"],
            "five points of per-speaker drift is past the tolerance"
        )
        let steady = try Self.score(
            werNoFiller: 0.38, attribution: 0.85, repeats: 0, tcpWer: 0.46
        )
        #expect(
            baselines.regressions(key: "parakeet/local/EN2002d", score: steady).isEmpty,
            "one point sits inside the tolerance"
        )
        // An entry recorded before the metric existed compares nothing.
        let legacy = BenchBaselines(entries: [
            "parakeet/local/EN2002d": BenchBaselines.Entry(
                wer: 0.40, werNoFiller: 0.38, attribution: 0.85, der: 0.30
            )
        ])
        #expect(
            legacy.regressions(key: "parakeet/local/EN2002d", score: drifted).isEmpty,
            "no recorded tcpWER means nothing to drift from"
        )
    }

    @Test("a repeat budget ratchets down and never up")
    func aRepeatBudgetRatchetsDownAndNeverUp() async throws {
        // The deciding run left two cases with repeats at a chunk seam.
        // Those two carry a budget so a clean sweep is green; every
        // other case still fails on a single repeated sentence.
        let baselines = BenchBaselines(entries: [
            "parakeet/local/IS1009c": BenchBaselines.Entry(
                wer: 0.30, werNoFiller: 0.28, attribution: 0.90, der: 0.20,
                repeatedNgrams: 7
            ),
            "parakeet/local/ES2002b": BenchBaselines.Entry(
                wer: 0.18, werNoFiller: 0.16, attribution: 0.99, der: 0.07,
                repeatedNgrams: 0
            ),
        ])

        let over = try Self.score(werNoFiller: 0.28, attribution: 0.90, repeats: 8)
        #expect(
            baselines.regressions(key: "parakeet/local/IS1009c", score: over)
                == ["8 repeated 8-grams against 7"],
            "one more repeat than the budget is a regression"
        )

        let atBudget = try Self.score(werNoFiller: 0.28, attribution: 0.90, repeats: 7)
        #expect(
            baselines.regressions(key: "parakeet/local/IS1009c", score: atBudget).isEmpty,
            "the recorded count itself passes"
        )

        let fewer = try Self.score(werNoFiller: 0.28, attribution: 0.90, repeats: 0)
        #expect(
            baselines.regressions(key: "parakeet/local/IS1009c", score: fewer).isEmpty,
            "removing repeats is never a failure"
        )

        let zeroBudget = try Self.score(werNoFiller: 0.16, attribution: 0.99, repeats: 1)
        #expect(
            baselines.regressions(key: "parakeet/local/ES2002b", score: zeroBudget)
                == ["1 repeated 8-grams against 0"],
            "a case recorded clean fails on a single repeat"
        )

        let unknown = try Self.score(werNoFiller: 0.16, attribution: 0.99, repeats: 1)
        #expect(
            baselines.regressions(key: "parakeet/local/IB4005", score: unknown)
                == ["1 repeated 8-grams against 0"],
            "and so does a case with no entry at all"
        )
    }

    @Test("the committed baselines carry the deciding run's repeats")
    func theCommittedBaselinesCarryTheDecidingRunsRepeats() async throws {
        let baselines = try BenchBaselines.read(
            from: Self.repositoryRoot.appendingPathComponent("Benchmarks/baselines.json")
        )
        #expect(baselines.entries["parakeet/local/ES2002c"]?.repeatedNgrams == 1)
        #expect(baselines.entries["parakeet/local/IS1009c"]?.repeatedNgrams == 7)
        #expect(baselines.entries["parakeet/local/ES2002b"]?.repeatedNgrams == 0)
    }

    @Test("every suite in the committed manifest names data that is there")
    func everySuiteInTheCommittedManifestNamesDataThatIsThere() async throws {
        let benchmarks = Self.repositoryRoot.appendingPathComponent("Benchmarks")
        let layout = BenchLayout(root: benchmarks)
        // The harness reads this file with `try?` and carries on
        // without checksums when it fails to decode, so a manifest
        // that stopped decoding would cost verification silently.
        let manifest = try BenchManifest.read(from: layout.manifest)
        #expect(manifest.annotations["ami"]?.sha256.count == 64)
        #expect(manifest.annotations["icsi"]?.sha256.count == 64)
        for (suite, roster) in manifest.suites {
            #expect(!roster.isEmpty, "\(suite) is empty")
            for meeting in roster {
                let truth = try BenchTruth.read(from: layout.truth(meeting: meeting))
                #expect(truth.meeting == meeting, "\(suite): truth names \(truth.meeting)")
                #expect(
                    manifest.audio[meeting]?.count == 64,
                    "\(suite): no checksum for \(meeting)"
                )
                // The fetch script names the downloaded file after the
                // last path component of its URL, and the truth's
                // `source` is what the harness then looks for.
                let url = manifest.audioURL?[meeting]
                    ?? manifest.mirror.replacingOccurrences(of: "{meeting}", with: meeting)
                let saved = manifest.audioFilename?[meeting]
                    ?? URL(string: url)?.lastPathComponent
                #expect(
                    saved == truth.source,
                    "\(suite): \(meeting) downloads under another name"
                )
            }
        }
    }

    @Test("the deciding suite holds no meeting an engine may have trained on")
    func theDecidingSuiteHoldsNoMeetingAnEngineMayHaveTrainedOn() async throws {
        // Parakeet's model card lists AMI in its training data, and
        // nine of the fourteen core cases sit in AMI's training
        // partition. A suite that ranks engines must not read them.
        let layout = BenchLayout(root: Self.repositoryRoot.appendingPathComponent("Benchmarks"))
        let manifest = try BenchManifest.read(from: layout.manifest)
        let partition = try #require(manifest.partition)
        for meeting in manifest.audio.keys {
            #expect(
                partition[meeting] != nil,
                "\(meeting) carries no partition, so nobody can tell what it may decide"
            )
        }
        // Spot checks against the published full-corpus-ASR split.
        #expect(partition["ES2002a"] == "ami-train")
        #expect(partition["IS1008a"] == "ami-dev")
        #expect(partition["EN2002a"] == "ami-eval")
        #expect(partition["IB4005"] == "excluded")
        #expect(partition["Bmr019"] == "clean")

        let deciding = try #require(manifest.suites["deciding"])
        for meeting in deciding {
            let held = partition[meeting] ?? "missing"
            #expect(
                held == "ami-eval" || held == "clean",
                "\(meeting) is \(held): only held-out or uncontaminated data may rank engines"
            )
        }
        #expect(deciding.contains("IS1009c"), "the long held-out case is in")
        #expect(deciding.contains("Bmr019"), "ICSI is in")
    }

    @Test("the overlap suites share no meeting with the core suite")
    func theOverlapSuitesShareNoMeetingWithTheCoreSuite() async throws {
        let layout = BenchLayout(root: Self.repositoryRoot.appendingPathComponent("Benchmarks"))
        let manifest = try BenchManifest.read(from: layout.manifest)
        // The exclusion is a flag on the generator command
        // (`--exclude-suite ami-core`), so forgetting it puts a meeting
        // the core suite already measures into the overlap roster and
        // the two numbers stop being independent.
        let core = Set(manifest.suites["ami-core"] ?? [])
        #expect(!core.isEmpty, "ami-core is empty")
        for suite in ["ami-overlap", "icsi"] {
            let roster = Set(manifest.suites[suite] ?? [])
            #expect(!roster.isEmpty, "\(suite) is empty")
            #expect(
                roster.intersection(core).sorted() == [],
                "\(suite) repeats meetings from ami-core"
            )
        }
    }

    @Test("the overlap suites are harder than the core suite")
    func theOverlapSuitesAreHarderThanTheCoreSuite() async throws {
        let layout = BenchLayout(root: Self.repositoryRoot.appendingPathComponent("Benchmarks"))
        let manifest = try BenchManifest.read(from: layout.manifest)
        // What the two new suites exist for. A regenerated truth that
        // lost the overlap ranking would still score, and score easy.
        for suite in ["ami-overlap", "icsi"] {
            for meeting in manifest.suites[suite] ?? [] {
                let truth = try BenchTruth.read(from: layout.truth(meeting: meeting))
                let ratio = truth.overlapRatio ?? 0
                #expect(ratio >= 0.25, "\(suite)/\(meeting) overlaps \(ratio), under 0.25")
            }
        }
    }

    @Test("repeated runs decide on the mean, and on the worst repeats")
    func repeatedRunsDecideOnTheMeanAndOnTheWorstRepeats() async throws {
        let runs = [
            try Self.run(wer: 0.20, attribution: 0.80, der: 0.30, repeats: 0, deletions: 11),
            try Self.run(wer: 0.30, attribution: 0.90, der: 0.50, repeats: 7, deletions: 22),
            try Self.run(wer: 0.40, attribution: 0.70, der: 0.40, repeats: 2, deletions: 33),
        ]
        let deciding = try #require(BenchAggregate.deciding(over: runs))
        #expect(abs(deciding.wer - 0.30) <= 0.0001, "expected \(0.30) ± \(0.0001), got \(deciding.wer)")
        #expect(
            abs(deciding.werNoFiller - 0.15) <= 0.0001,
            "expected \(0.15) ± \(0.0001), got \(deciding.werNoFiller)"
        )
        #expect(
            abs(deciding.werConversational - 0.075) <= 0.0001,
            "expected \(0.075) ± \(0.0001), got \(deciding.werConversational)"
        )
        #expect(
            abs(deciding.attribution - 0.80) <= 0.0001,
            "expected \(0.80) ± \(0.0001), got \(deciding.attribution)"
        )
        #expect(
            abs(deciding.attributionMerged - 0.85) <= 0.0001,
            "expected \(0.85) ± \(0.0001), got \(deciding.attributionMerged)"
        )
        #expect(
            abs(deciding.attributionOfLabelled - 0.82) <= 0.0001,
            "expected \(0.82) ± \(0.0001), got \(deciding.attributionOfLabelled)"
        )
        let der = try #require(deciding.der)
        #expect(abs(der - 0.40) <= 0.0001, "expected \(0.40) ± \(0.0001), got \(der)")
        let derStrict = try #require(deciding.derStrict)
        #expect(abs(derStrict - 0.50) <= 0.0001, "expected \(0.50) ± \(0.0001), got \(derStrict)")
        #expect(
            deciding.repeatedNgrams == 7,
            "the repeat budget is worst of the runs, because a defect seen once is one"
        )
        #expect(
            deciding.deletions == 11,
            "a count describes one transcript and keeps the first run's value"
        )
        #expect(deciding.clusterMapping == ["c11": "A"])
        #expect(
            abs(deciding.orderingFloorWer - 0.1) <= 0.0001,
            "expected \(0.1) ± \(0.0001), got \(deciding.orderingFloorWer)"
        )

        let alone = try #require(BenchAggregate.deciding(over: [runs[1]]))
        #expect(alone == runs[1], "one run decides as itself")
        #expect(BenchAggregate.deciding(over: []) == nil, "no runs decide nothing")
    }

    @Test("repeated runs decide per-speaker error on the mean")
    func repeatedRunsDecidePerSpeakerErrorOnTheMean() async throws {
        let first = try Self.score(werNoFiller: 0.20, attribution: 0.95, repeats: 0, tcpWer: 0.40)
        let second = try Self.score(werNoFiller: 0.20, attribution: 0.95, repeats: 0, tcpWer: 0.50)
        let deciding = try #require(BenchAggregate.deciding(over: [first, second]))
        let decidingTcpWer = try #require(deciding.tcpWer)
        #expect(
            abs(decidingTcpWer - 0.45) <= 0.0001,
            "expected \(0.45) ± \(0.0001), got \(decidingTcpWer) — the gate reads the mean of the runs"
        )
        let legacy = try Self.score(werNoFiller: 0.20, attribution: 0.95, repeats: 0)
        let mixed = try #require(BenchAggregate.deciding(over: [legacy, first]))
        let mixedTcpWer = try #require(mixed.tcpWer)
        #expect(
            abs(mixedTcpWer - 0.40) <= 0.0001,
            "expected \(0.40) ± \(0.0001), got \(mixedTcpWer) — a run recorded before the metric existed does not drag the mean"
        )
    }

    @Test("a resumed run skips what the out file already holds")
    func aResumedRunSkipsWhatTheOutFileAlreadyHolds() async throws {
        func row(_ meeting: String, engine: String, diarizer: String, run: Int) throws -> BenchRow {
            var recorded = try Self.score(werNoFiller: 0.2, attribution: 0.9, repeats: 0)
            recorded.meeting = meeting
            return BenchRow(
                engine: engine, diarizer: diarizer, score: recorded,
                processingSeconds: 60, audioSeconds: 360, state: "complete",
                transcriptionModels: [], diarizationBackends: [],
                overlapRatio: nil, run: run, scratch: nil
            )
        }
        let existing = [
            try row("ES2002b", engine: "parakeet", diarizer: "local", run: 1),
            try row("ES2002b", engine: "parakeet", diarizer: "local", run: 3),
            try row("ES2002b", engine: "cohere", diarizer: "local", run: 1),
        ]
        let plan = BenchResume.pending(
            existing: existing, meeting: "ES2002b",
            engine: "parakeet", diarizer: "local", repeats: 3
        )
        #expect(plan.runs == [2], "runs one and three are already on disk")
        #expect(plan.done.count == 2, "the recorded runs still feed the mean")

        let fresh = BenchResume.pending(
            existing: existing, meeting: "ES2002b",
            engine: "parakeet", diarizer: "lseend", repeats: 2
        )
        #expect(
            fresh.runs == [1, 2],
            "a different diarizer shares nothing with the recorded rows"
        )
        #expect(fresh.done.count == 0)
    }

    @Test("a run with no DER leaves the aggregate without one")
    func aRunWithNoDERLeavesTheAggregateWithoutOne() async throws {
        let runs = [
            try Self.run(wer: 0.2, attribution: 0.8, der: nil, repeats: 0, deletions: 1),
            try Self.run(wer: 0.4, attribution: 0.6, der: nil, repeats: 0, deletions: 2),
        ]
        let deciding = try #require(BenchAggregate.deciding(over: runs))
        #expect(deciding.der == nil, "no run measured DER")
        #expect(abs(deciding.wer - 0.30) <= 0.0001, "expected \(0.30) ± \(0.0001), got \(deciding.wer)")
    }
}
