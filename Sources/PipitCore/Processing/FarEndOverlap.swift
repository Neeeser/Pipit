import Foundation

/// Drops a microphone line that is the far end's own words, said at the same
/// moment.
///
/// The far end plays out of the speakers and back into the microphone. The
/// canceller takes most of it out, and what it leaves is transcribed under the
/// user's name. On the Zoom call of 11 September 2026 the speakers were loud
/// and the echo path nonlinear: 249 of the 268 lines on the microphone were
/// the far end's words, within three seconds of the far end's own line.
///
/// A line goes when it holds `minimumWords` content words and `overlapShare`
/// of them are also a far-end word spoken within `wordGapSeconds` of it. The
/// moment is judged per word: echo is the same sound arriving a fraction of a
/// second late, so each of its words sits on the far end's own, while a person
/// who answers in the far end's words says each of them seconds later. Judged
/// by the lines' spans, as it first was, a conversation that overlapped by a
/// few words lost real lines. On the simulated calls, which have no echo on the
/// headphone variant, it removed about 2% of the local person's words, and the
/// same rule took 20 words from a recorded 11-minute call. The lines it took
/// wrongly shared 0% to 50% of their words at the same moment, within a second
/// either way; the lines of a call whose microphone held the far end shared 83%
/// to 100%. A short reply stays,
/// because "sounds right" is what a person says back. A sentence with its own
/// words stays, because sharing a few nouns with the far end is a
/// conversation.
///
/// One line can hold both: the transcript joins segments a second apart, so a
/// stretch of the user's own words and a stretch of echo become one line. A
/// timed line is therefore searched for the run of words that is the
/// far end's, and that run goes while the words around it stay. A line without
/// word timings is judged whole by its span, as is a far-end line without them,
/// because a backend that returns text only gives no moment to compare.
public enum FarEndOverlap {
    /// Content words a line needs before it can be judged.
    public static let minimumWords = 4
    /// Share of them that have to be the far end's.
    public static let overlapShare = 0.6
    /// How close in time a word has to be to the far end's same word to be
    /// that word's echo.
    public static let wordGapSeconds = 1.0

    public static func drop(_ utterances: [Utterance]) -> [Utterance] {
        let farEnd = utterances.filter { $0.track != .mic }
        guard !farEnd.isEmpty else { return utterances }
        var theirs: [String: [TimedWord]] = [:]
        for word in farEnd.flatMap(timedTokens) { theirs[word.text, default: []].append(word) }
        return utterances.flatMap { utterance -> [Utterance] in
            guard utterance.track == .mic else { return [utterance] }
            return keeping(utterance, among: theirs)
        }
    }

    /// A word and the span it was spoken over.
    struct TimedWord {
        var text: String
        var start: Double
        var end: Double
    }

    /// What is left of a microphone line once the far end's words are taken
    /// out: nothing, the line itself, or the stretches around a removed run.
    static func keeping(_ utterance: Utterance, among farEnd: [String: [TimedWord]]) -> [Utterance] {
        guard let words = utterance.words, !words.isEmpty else {
            return isFarEnd(timedTokens(utterance), among: farEnd) ? [] : [utterance]
        }
        return pieces(of: utterance, words: words[...], among: farEnd)
    }

    private static func pieces(
        of utterance: Utterance, words: ArraySlice<RawTranscriptWord>,
        among farEnd: [String: [TimedWord]]
    ) -> [Utterance] {
        guard let run = echoRun(in: words, among: farEnd) else {
            return words.isEmpty ? [] : [rebuilt(utterance, words: words)]
        }
        return pieces(of: utterance, words: words[..<run.lowerBound], among: farEnd)
            + pieces(of: utterance, words: words[run.upperBound...], among: farEnd)
    }

    /// The stretch of `words` that is the far end's, as the indices of the words
    /// it covers, or nil when none holds `minimumWords` content words with
    /// `overlapShare` of them the far end's.
    ///
    /// A stretch starts and ends on a word the far end said at that moment, so
    /// a user's word beside the echo is not taken with it for the sake of the
    /// share. Of the stretches that qualify, the one with the most echoed words
    /// wins. The short words the echo is made of, which the far end said too,
    /// go with it.
    private static func echoRun(
        in words: ArraySlice<RawTranscriptWord>, among farEnd: [String: [TimedWord]]
    ) -> Range<Int>? {
        var content: [(index: Int, echoed: Bool)] = []
        for index in words.indices {
            let word = words[index]
            for text in tokens(word.text) where text.count >= minimumLetters {
                let timed = TimedWord(text: text, start: word.start, end: word.end)
                content.append((index, isEcho(timed, among: farEnd)))
            }
        }
        guard content.count >= minimumWords else { return nil }
        var prefix = [0]
        for entry in content { prefix.append((prefix.last ?? 0) + (entry.echoed ? 1 : 0)) }
        var best: (first: Int, last: Int, echoed: Int)?
        for first in 0..<content.count where content[first].echoed {
            for last in first..<content.count where content[last].echoed {
                let count = last - first + 1
                let echoed = prefix[last + 1] - prefix[first]
                guard count >= minimumWords, Double(echoed) / Double(count) >= overlapShare
                else { continue }
                if best.map({ echoed > $0.echoed }) ?? true { best = (first, last, echoed) }
            }
        }
        guard let best else { return nil }
        var lower = content[best.first].index
        var upper = content[best.last].index + 1
        while lower > words.startIndex, isEcho(words[lower - 1], among: farEnd) { lower -= 1 }
        while upper < words.endIndex, isEcho(words[upper], among: farEnd) { upper += 1 }
        return lower..<upper
    }

    private static func rebuilt(
        _ utterance: Utterance, words: ArraySlice<RawTranscriptWord>
    ) -> Utterance {
        guard words.count < (utterance.words?.count ?? 0), let first = words.first, let last = words.last
        else { return utterance }
        var piece = utterance
        piece.words = Array(words)
        piece.text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        piece.start = first.start
        piece.end = last.end
        piece.id = Utterance.identifier(
            chunkID: piece.chunkID, track: piece.track, start: piece.start, end: piece.end)
        return piece
    }

    static func isFarEnd(_ line: [TimedWord], among farEnd: [String: [TimedWord]]) -> Bool {
        let own = line.filter { $0.text.count >= minimumLetters }
        guard own.count >= minimumWords else { return false }
        let echoed = own.filter { isEcho($0, among: farEnd) }.count
        return Double(echoed) / Double(own.count) >= overlapShare
    }

    /// Whether every token of a word is one the far end said at that moment.
    private static func isEcho(_ word: RawTranscriptWord, among farEnd: [String: [TimedWord]]) -> Bool {
        let texts = tokens(word.text)
        return !texts.isEmpty
            && texts.allSatisfy {
                isEcho(TimedWord(text: $0, start: word.start, end: word.end), among: farEnd)
            }
    }

    private static func isEcho(_ word: TimedWord, among farEnd: [String: [TimedWord]]) -> Bool {
        farEnd[word.text]?.contains { other in
            max(word.start, other.start) - min(word.end, other.end) <= wordGapSeconds
        } ?? false
    }

    /// The words of a line with the span of each. A line with word timings
    /// gives each word its own; one without gives every word the span of the
    /// line.
    static func timedTokens(_ utterance: Utterance) -> [TimedWord] {
        if let words = utterance.words, !words.isEmpty {
            return words.flatMap { word in
                tokens(word.text).map { TimedWord(text: $0, start: word.start, end: word.end) }
            }
        }
        return tokens(utterance.text).map {
            TimedWord(text: $0, start: utterance.start, end: utterance.end)
        }
    }

    /// Letters or digits a word needs to count toward the share. Shorter ones
    /// are the function words both sides say.
    static let minimumLetters = 3

    /// Lowercased words of the text, without punctuation, which is the
    /// decoder's.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { $0.filter { $0 != "'" } }
            .filter { !$0.isEmpty }
    }
}
