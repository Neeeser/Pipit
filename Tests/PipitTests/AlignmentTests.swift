import Foundation
import PipitCore
import Testing

/// CTC forced alignment: given frame log-probabilities and the known
/// transcript, recover when each word was said. This is what lets a
/// transcription model that returns no timings feed the timeline.
@Suite("ForcedAlignment")
struct ForcedAlignmentTests {
    /// Log-probabilities where each frame strongly prefers one symbol.
    /// `peaks[t]` is the preferred vocabulary index at frame t.
    private static func peaked(_ peaks: [Int], vocabularySize: Int) -> [[Float]] {
        peaks.map { peak in
            (0..<vocabularySize).map { $0 == peak ? Float(-0.01) : Float(-8.0) }
        }
    }

    @Test("words land on the frames that spoke them")
    func wordsLandOnTheFramesThatSpokeThem() async throws {
        // Vocabulary: 0,1,2 are tokens, 3 is blank. "ab" = [0,1], "c" = [2].
        let logProbs = Self.peaked([0, 0, 3, 1, 3, 2, 2, 3, 3], vocabularySize: 4)
        let words = try #require(CtcForcedAlignment.align(
            logProbs: logProbs, frameDuration: 0.1, blankId: 3,
            words: [
                CtcForcedAlignment.TokenizedWord(text: "ab", tokens: [0, 1]),
                CtcForcedAlignment.TokenizedWord(text: "c", tokens: [2]),
            ]
        ))
        #expect(words.map(\.text) == ["ab", "c"])
        #expect(abs(words[0].start - 0.0) <= 0.001, "expected \(0.0) ± \(0.001), got \(words[0].start)")
        #expect(
            abs(words[0].end - 0.4) <= 0.001,
            "expected \(0.4) ± \(0.001), got \(words[0].end) — token 1 ends after frame 3"
        )
        #expect(abs(words[1].start - 0.5) <= 0.001, "expected \(0.5) ± \(0.001), got \(words[1].start)")
        #expect(
            abs(words[1].end - 0.7) <= 0.001,
            "expected \(0.7) ± \(0.001), got \(words[1].end) — token 2 held frames 5 and 6"
        )
    }

    @Test("a repeated token forces a blank between occurrences")
    func aRepeatedTokenForcesABlankBetweenOccurrences() async throws {
        // "aa" as [0, 0] needs blank-separated occurrences: 0, blank, 0.
        let logProbs = Self.peaked([0, 3, 0, 3], vocabularySize: 4)
        let words = try #require(CtcForcedAlignment.align(
            logProbs: logProbs, frameDuration: 0.1, blankId: 3,
            words: [CtcForcedAlignment.TokenizedWord(text: "aa", tokens: [0, 0])]
        ))
        #expect(abs(words[0].start - 0.0) <= 0.001, "expected \(0.0) ± \(0.001), got \(words[0].start)")
        #expect(abs(words[0].end - 0.3) <= 0.001, "expected \(0.3) ± \(0.001), got \(words[0].end)")
    }

    @Test("too few frames for the transcript refuses instead of inventing")
    func tooFewFramesForTheTranscriptRefusesInsteadOfInventing() async throws {
        let logProbs = Self.peaked([0], vocabularySize: 4)
        #expect(CtcForcedAlignment.align(
                logProbs: logProbs, frameDuration: 0.1, blankId: 3,
                words: [CtcForcedAlignment.TokenizedWord(text: "abc", tokens: [0, 1, 2])]
            ) == nil, "one frame cannot carry three tokens")
    }

    @Test("an oversized trellis refuses instead of exhausting memory")
    func anOversizedTrellisRefusesInsteadOfExhaustingMemory() async throws {
        let logProbs = Self.peaked(Array(repeating: 0, count: 50), vocabularySize: 4)
        #expect(CtcForcedAlignment.align(
                logProbs: logProbs, frameDuration: 0.1, blankId: 3,
                words: [CtcForcedAlignment.TokenizedWord(text: "a", tokens: [0])],
                maximumCells: 100
            ) == nil, "the caller falls back to chunk-level timing instead")
    }

    @Test("a crammed run is spread between its aligned neighbours")
    func aCrammedRunIsSpreadBetweenItsAlignedNeighbours() async throws {
        // Four one-frame words stacked at 2.5s, between a word ending
        // at 2.0 and one starting at 6.0: a weak-posterior stretch.
        var words = [
            CtcForcedAlignment.AlignedWord(text: "good", start: 1.0, end: 2.0)
        ]
        for offset in 0..<4 {
            let start = 2.5 + Double(offset) * 0.08
            words.append(CtcForcedAlignment.AlignedWord(
                text: "crammed\(offset)", start: start, end: start + 0.08
            ))
        }
        words.append(CtcForcedAlignment.AlignedWord(text: "fine", start: 6.0, end: 6.5))

        let spread = CtcForcedAlignment.spreadCrammedRuns(words, frameDuration: 0.08)
        #expect(spread[0] == words[0], "an aligned word keeps its timing")
        #expect(spread[5] == words[5])
        #expect(
            abs(spread[1].start - 2.0) <= 0.001,
            "expected \(2.0) ± \(0.001), got \(spread[1].start) — the run starts after its anchor"
        )
        #expect(
            abs(spread[4].end - 6.0) <= 0.001,
            "expected \(6.0) ± \(0.001), got \(spread[4].end) — and ends at the next one"
        )
        #expect(
            abs((spread[2].end - spread[2].start) - 1.0) <= 0.001,
            "expected \(1.0) ± \(0.001), got \(spread[2].end - spread[2].start) — four words share the four-second gap evenly"
        )
    }

    @Test("a short cram and honest short words stay put")
    func aShortCramAndHonestShortWordsStayPut() async throws {
        let words = [
            CtcForcedAlignment.AlignedWord(text: "I", start: 0.0, end: 0.08),
            CtcForcedAlignment.AlignedWord(text: "do", start: 0.1, end: 0.18),
            CtcForcedAlignment.AlignedWord(text: "agree", start: 0.4, end: 0.9),
        ]
        #expect(
            CtcForcedAlignment.spreadCrammedRuns(words, frameDuration: 0.08) == words,
            "two short words in a row are normal speech, not a degenerate path"
        )
    }

    @Test("empty input aligns to nothing")
    func emptyInputAlignsToNothing() async throws {
        #expect(CtcForcedAlignment.align(
                logProbs: Self.peaked([3, 3], vocabularySize: 4), frameDuration: 0.1,
                blankId: 3, words: []
            )?.count == 0, "no words is a valid, empty alignment")
    }

}

@Suite("AlignedSegments")
struct AlignedSegmentsTests {
    @Test("a pause starts a new segment")
    func aPauseStartsANewSegment() async throws {
        let words = [
            CtcForcedAlignment.AlignedWord(text: "hello", start: 0.0, end: 0.4),
            CtcForcedAlignment.AlignedWord(text: "there", start: 0.5, end: 0.9),
            CtcForcedAlignment.AlignedWord(text: "general", start: 3.0, end: 3.6),
        ]
        let segments = CtcForcedAlignment.segments(
            from: words, pauseSeconds: 1.0, maximumSeconds: 30
        )
        #expect(segments.count == 2)
        #expect(segments.first?.text == "hello there")
        #expect(segments.first?.words?.count == 2)
        #expect(
            abs((segments.last?.start ?? 0) - 3.0) <= 0.001,
            "expected \(3.0) ± \(0.001), got \(segments.last?.start ?? 0)"
        )
    }

    @Test("a monologue splits at the duration cap")
    func aMonologueSplitsAtTheDurationCap() async throws {
        let words = (0..<40).map {
            CtcForcedAlignment.AlignedWord(
                text: "w\($0)", start: Double($0), end: Double($0) + 0.5
            )
        }
        let segments = CtcForcedAlignment.segments(
            from: words, pauseSeconds: 1.0, maximumSeconds: 10
        )
        #expect(segments.count > 1, "40 seconds of speech never stays one segment")
        #expect(segments.allSatisfy { ($0.end - $0.start) <= 10.5 }, "every segment respects the cap")
        #expect(segments.flatMap { $0.words ?? [] }.count == 40, "no word is lost to the splitting")
    }

}
