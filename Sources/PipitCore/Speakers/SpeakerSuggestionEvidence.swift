import Foundation

/// Checks a suggested name against the line the model said earned it.
///
/// The model is asked to name a speaker only where somebody says that name out
/// loud, and to quote the line with the timestamp it carries. Both halves of
/// that answer are checkable against the transcript it was reading, and the
/// ones that fail are the ones that were wrong.
///
/// Measured over the fourteen suggestions on disk. Nine are right and every one
/// of them cites a line within 8 seconds of where the transcript actually holds
/// it, with the named speaker talking within 57 seconds of it. Of the five that
/// are wrong, three cite a line 20, 425 and 1612 seconds from where it really
/// is, and a fourth names a speaker who does not talk within 72 seconds of the
/// line it quotes. On a standup of 10 September 2026 that fourth one was
/// offered at 0.93: the quoted line belonged to one speaker the meeting had
/// already named, the person who answered it was another, and the label being
/// named had not said anything for a minute either side.
///
/// The one that survives is a 26-second fragment of somebody else's sentences
/// quoting a line that does sit beside it. Nothing here separates that from a
/// real answer, and a check that would is a check that costs real names.
public enum SpeakerSuggestionEvidence {
    /// How far the timestamp may sit from where the quoted line really is.
    ///
    /// The nine right answers are inside 8 seconds. Of the wrong ones, two are
    /// 425 and 1612 seconds out and one is 20, which this lets through and the
    /// reach below catches instead. Thirty is 3.75x above the worst genuine
    /// reading and 14x below the nearest false one it is meant to refuse.
    public static let quoteDriftSeconds: Double = 30

    /// How far the named speaker may be from the line that names them.
    ///
    /// The pattern the model is told to look for is one person addressing
    /// another and that person speaking next or just before, so the speaker
    /// being named has to be somewhere near the line. Sixty seconds is
    /// deliberately loose: one right answer sits 57 seconds away, from a model
    /// that read an introduction at the top of the call and confirmed it
    /// against what the speaker said later.
    public static let labelReachSeconds: Double = 60

    /// Share of a quote's words that have to be found together before the
    /// transcript is agreed to hold that line at all.
    ///
    /// Not all of them: the model retypes a quote from a rendered transcript,
    /// and punctuation, filler and the joins between utterances move.
    public static let minimumQuoteMatch = 0.6

    /// The suggestions whose own evidence holds up.
    public static func verified(
        _ suggestions: [SpeakerNameSuggestion], against transcript: CanonicalTranscript
    ) -> [SpeakerNameSuggestion] {
        let words = tokens(of: transcript)
        return suggestions.filter { verify($0, words: words, transcript: transcript) != nil }
    }

    private static func verify(
        _ suggestion: SpeakerNameSuggestion, words: [Token], transcript: CanonicalTranscript
    ) -> Double? {
        let quote = normalise(stripRenderedPrefix(suggestion.quote))
        guard !quote.isEmpty, let at = locate(quote, in: words) else { return nil }
        guard abs(at - suggestion.atSeconds) <= quoteDriftSeconds else { return nil }
        let spoken = transcript.utterances.filter { $0.speakerKey == suggestion.label }
        guard !spoken.isEmpty else { return nil }
        let reach =
            spoken.map { utterance -> Double in
                if utterance.start <= at, at <= utterance.end { return 0 }
                return min(abs(utterance.start - at), abs(utterance.end - at))
            }.min() ?? .greatestFiniteMagnitude
        guard reach <= labelReachSeconds else { return nil }
        return at
    }

    private struct Token {
        var text: String
        var start: Double
    }

    private static func tokens(of transcript: CanonicalTranscript) -> [Token] {
        transcript.utterances
            .sorted { $0.start < $1.start }
            .flatMap { utterance -> [Token] in
                guard let words = utterance.words, !words.isEmpty else {
                    // No word timings, so every token of the line is placed at
                    // the line's own start. Coarser and still inside the drift.
                    return normalise(utterance.text).map { Token(text: $0, start: utterance.start) }
                }
                return words.flatMap { word in
                    normalise(word.text).map { Token(text: $0, start: word.start) }
                }
            }
    }

    /// Where a run of the transcript best matches the quote, or nil where none
    /// of them matches enough of it.
    ///
    /// A window the length of the quote, compared as a bag of words rather than
    /// in order. The model's copy of a line is close to the transcript's and
    /// rarely identical: it joins two utterances, drops a filler, or writes a
    /// name the recogniser spelled differently.
    private static func locate(_ quote: [String], in words: [Token]) -> Double? {
        guard words.count >= quote.count else { return nil }
        var wanted: [String: Int] = [:]
        for word in quote { wanted[word, default: 0] += 1 }
        var have: [String: Int] = [:]
        var matched = 0
        var best = 0
        var bestAt: Int?

        func add(_ word: String) {
            have[word, default: 0] += 1
            if have[word, default: 0] <= wanted[word, default: 0] { matched += 1 }
        }
        func remove(_ word: String) {
            if have[word, default: 0] <= wanted[word, default: 0] { matched -= 1 }
            have[word, default: 0] -= 1
        }

        for index in words.indices {
            add(words[index].text)
            if index >= quote.count { remove(words[index - quote.count].text) }
            if matched > best {
                best = matched
                bestAt = max(0, index - quote.count + 1)
            }
        }
        guard let bestAt, Double(best) / Double(quote.count) >= minimumQuoteMatch else {
            return nil
        }
        return words[bestAt].start
    }

    /// The line without the timecode and speaker the transcript was rendered
    /// with, where the model quoted the row rather than the words in it.
    ///
    /// The prompt asks for the line verbatim and one model reads that as the
    /// whole row: `[00:17] remote-001_speaker_02: Ellis. When do you`. Six of
    /// its ten words are then the row's furniture, which is enough to lose a
    /// right answer.
    private static func stripRenderedPrefix(_ quote: String) -> String {
        let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else {
            return trimmed
        }
        let rest = trimmed[trimmed.index(after: close)...]
        // The speaker runs to the first colon, and a line of speech with no
        // colon in it leaves the rest alone.
        guard let colon = rest.firstIndex(of: ":") else { return String(rest) }
        return String(rest[rest.index(after: colon)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words, lower-cased, with everything that is not a letter, a digit or an
    /// apostrophe dropped.
    private static func normalise(_ text: String) -> [String] {
        text.lowercased()
            .split { character in
                !(character.isLetter || character.isNumber || character == "'")
            }
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
