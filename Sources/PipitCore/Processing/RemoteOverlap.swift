import Foundation

/// Removes the remote track's own words from the local person's microphone lines.
///
/// The call audio plays out of the speakers and back into the microphone. The
/// canceller takes most of it out, and what it leaves is transcribed under the
/// user's name. On the Zoom call of 11 September 2026 the speakers were loud
/// and the echo path nonlinear: 249 of the 268 lines on the microphone were
/// the remote track's words, within a second or so of the remote track's own line.
///
/// Two goals pull against each other: the local person's own words are never
/// dropped, and the remote track's words are never shown under the local person.
/// When they conflict, the local person's words win.
///
/// A microphone word is echo when it is a remote word spoken within
/// `wordGapSeconds` of it. The moment is judged per word: echo is the same
/// sound arriving a fraction of a second late, so each of its words sits on the
/// remote track's own, while a person who answers in the remote track's words says each
/// of them seconds later. Judged by the lines' spans, as it first was, a
/// conversation that overlapped by a few words lost real lines.
///
/// Each remote word can be the source of one microphone word, so a person who
/// repeats a word the other people on the call said once does not count as echoing it again.
/// Backchannels (`ignoredWords`) are neither echo nor the person's own
/// content: both sides say them, so they cannot show whose voice it is. A reply
/// made of them stays. They still go with a run of echo they sit inside.
///
/// A run of echo is a stretch of content words that holds `minimumWords` echoed
/// ones and `overlapShare` of its content words echoed. A run ends at a
/// stretch of the person's own content words: at most one non-echo content word
/// is tolerated between two echoed ones, since the microphone mis-hears an
/// echoed word now and then. So echo, the person's sentence, and more echo
/// give two runs and the sentence stays. Lines that are less than
/// `poolGapSeconds` apart are searched as one, because an echo can be split
/// across two lines and neither part is long enough alone.
///
/// A mis-heard word at the edge of a run ("fry day" for "friday") matches
/// nothing, so it is left behind unless the words next to the run are close in
/// spelling to the remote words that follow or precede the run's source, and
/// fall in the remote line's span. At most `maximumLeftoverWords` go that way,
/// so the person's real words after an echo stay.
///
/// A line without word timings gives every word the span of the line and is
/// judged whole, as is a remote line without them, because a backend that
/// returns text only gives no moment to compare.
public enum RemoteOverlap {
    /// Content words a run needs before it can be judged.
    public static let minimumWords = 4
    /// Share of a run's content words that have to be the remote track's.
    public static let overlapShare = 0.6
    /// How close in time a word has to be to the remote track's same word to be
    /// that word's echo.
    public static let wordGapSeconds = 1.0
    /// Microphone lines closer than this are searched for echo as one line.
    public static let poolGapSeconds = 2.0
    /// Words beside a run that can be taken as its mis-heard edge.
    static let maximumLeftoverWords = 2
    /// Edit distance, as a share of the longer spelling, up to which a leftover
    /// reads as a mis-hearing of the remote words next to the run's source.
    static let leftoverSpellingTolerance = 0.4

    public static func drop(_ utterances: [Utterance]) -> [Utterance] {
        let remote = utterances.filter { $0.track != .mic }
        guard !remote.isEmpty else { return utterances }
        var theirs = RemoteWords(remote)
        var lines = utterances.indices
            .filter { utterances[$0].track == .mic }
            .sorted { utterances[$0].start < utterances[$1].start }
            .map { MicLine(index: $0, utterance: utterances[$0]) }
        theirs.pair(&lines)

        var replacement: [Int: [Utterance]] = [:]
        var group: [MicLine] = []
        func flush() {
            for (index, pieces) in remaining(of: group, theirs: theirs) { replacement[index] = pieces }
            group = []
        }
        for line in lines {
            if let last = group.last,
                line.timed, last.timed,
                line.utterance.start - last.utterance.end <= poolGapSeconds
            {
                group.append(line)
            } else {
                flush()
                group = [line]
            }
        }
        flush()
        return utterances.indices.flatMap { replacement[$0] ?? [utterances[$0]] }
    }

    // MARK: Words

    struct Token {
        var text: String
        var start: Double
        var end: Double
        /// Whether it counts toward a run: long enough and not an ignored word.
        var content: Bool
        /// For a content word, whether it was paired with a remote word. For
        /// any other, whether a remote word matches it at that moment.
        var echoed = false
        /// The remote word a content word was paired with.
        var source: Int?

        init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
            content = text.count >= RemoteOverlap.minimumLetters && !RemoteOverlap.ignoredWords.contains(text)
        }
    }

    /// One transcript word with the tokens it holds. A line without word
    /// timings has one unit per token.
    struct Unit {
        var tokens: [Token]
        var start: Double
        var end: Double
    }

    struct MicLine {
        var index: Int
        var utterance: Utterance
        var units: [Unit]
        var timed: Bool

        init(index: Int, utterance: Utterance) {
            self.index = index
            self.utterance = utterance
            if let words = utterance.words, !words.isEmpty {
                timed = true
                units = words.map { word in
                    Unit(
                        tokens: RemoteOverlap.tokens(word.text).map {
                            Token(text: $0, start: word.start, end: word.end)
                        },
                        start: word.start, end: word.end)
                }
            } else {
                timed = false
                units = RemoteOverlap.tokens(utterance.text).map {
                    Unit(
                        tokens: [Token(text: $0, start: utterance.start, end: utterance.end)],
                        start: utterance.start, end: utterance.end)
                }
            }
        }
    }

    /// The remote track's words, each of which can be claimed by one microphone word.
    struct RemoteWords {
        struct Word {
            var text: String
            var start: Double
            var end: Double
            var line: Int
            var position: Int
        }

        var words: [Word] = []
        var byText: [String: [Int]] = [:]
        var lines: [[Int]] = []
        var lineSpans: [(start: Double, end: Double)] = []
        var claimed: Set<Int> = []

        init(_ utterances: [Utterance]) {
            for (line, utterance) in utterances.enumerated() {
                var ids: [Int] = []
                let spans: [(String, Double, Double)]
                if let timed = utterance.words, !timed.isEmpty {
                    spans = timed.flatMap { word in
                        RemoteOverlap.tokens(word.text).map { ($0, word.start, word.end) }
                    }
                } else {
                    spans = RemoteOverlap.tokens(utterance.text).map { ($0, utterance.start, utterance.end) }
                }
                for (position, span) in spans.enumerated() {
                    ids.append(words.count)
                    byText[span.0, default: []].append(words.count)
                    words.append(Word(text: span.0, start: span.1, end: span.2, line: line, position: position))
                }
                lines.append(ids)
                lineSpans.append((spans.map(\.1).min() ?? utterance.start, spans.map(\.2).max() ?? utterance.end))
            }
        }

        static func near(_ token: Token, _ word: Word) -> Bool {
            max(token.start, word.start) - min(token.end, word.end) <= RemoteOverlap.wordGapSeconds
        }

        /// Marks which microphone tokens are echo. Content words claim the
        /// nearest remote word in time that nobody has claimed, working through
        /// the microphone in time order; the others only look for a match.
        mutating func pair(_ lines: inout [MicLine]) {
            var order: [(line: Int, unit: Int, token: Int)] = []
            for (lineIndex, line) in lines.enumerated() {
                for (unitIndex, unit) in line.units.enumerated() {
                    for tokenIndex in unit.tokens.indices {
                        order.append((lineIndex, unitIndex, tokenIndex))
                    }
                }
            }
            order.sort { lhs, rhs in
                lines[lhs.line].units[lhs.unit].start < lines[rhs.line].units[rhs.unit].start
            }
            for entry in order {
                let token = lines[entry.line].units[entry.unit].tokens[entry.token]
                let candidates = (byText[token.text] ?? []).filter { Self.near(token, words[$0]) }
                if token.content {
                    let mid = (token.start + token.end) / 2
                    let best =
                        candidates
                        .filter { !claimed.contains($0) }
                        .min {
                            abs((words[$0].start + words[$0].end) / 2 - mid)
                                < abs((words[$1].start + words[$1].end) / 2 - mid)
                        }
                    if let best {
                        claimed.insert(best)
                        lines[entry.line].units[entry.unit].tokens[entry.token].echoed = true
                        lines[entry.line].units[entry.unit].tokens[entry.token].source = best
                    }
                } else {
                    lines[entry.line].units[entry.unit].tokens[entry.token].echoed = !candidates.isEmpty
                }
            }
        }
    }

    // MARK: Runs

    /// The pieces each line of a pool becomes once its echo is taken out:
    /// nothing, the line itself, or the stretches around a removed run.
    private static func remaining(
        of group: [MicLine], theirs: RemoteWords
    ) -> [(Int, [Utterance])] {
        guard let first = group.first else { return [] }
        guard first.timed else {
            let content = first.units.flatMap(\.tokens).filter(\.content)
            let echo =
                content.count >= minimumWords
                && Double(content.filter(\.echoed).count) / Double(content.count) >= overlapShare
            return [(first.index, echo ? [] : [first.utterance])]
        }
        let removed = echoUnits(in: group.flatMap(\.units), theirs: theirs)
        var base = 0
        var result: [(Int, [Utterance])] = []
        for line in group {
            defer { base += line.units.count }
            let words = line.utterance.words ?? []
            var pieces: [Utterance] = []
            var start = 0
            for end in 0...words.count where end == words.count || removed.contains(base + end) {
                if end > start { pieces.append(rebuilt(line.utterance, words: words[start..<end])) }
                start = end + 1
            }
            result.append((line.index, pieces))
        }
        return result
    }

    /// The indices of the units that are echo. Each run holds `minimumWords`
    /// echoed content words and `overlapShare` of its content words echoed, and
    /// is cut at a stretch of the person's own content words.
    private static func echoUnits(in units: [Unit], theirs: RemoteWords) -> Set<Int> {
        let content = units.enumerated().flatMap { index, unit in
            unit.tokens.filter(\.content).map { (unit: index, token: $0) }
        }
        var runs: [ClosedRange<Int>] = []
        var open: ClosedRange<Int>?
        var gap = 0
        for position in content.indices {
            guard content[position].token.echoed else {
                gap += 1
                continue
            }
            if let current = open, gap <= 1 {
                open = current.lowerBound...position
            } else {
                if let current = open { runs.append(current) }
                open = position...position
            }
            gap = 0
        }
        if let open { runs.append(open) }

        var removed: Set<Int> = []
        for run in runs {
            let echoed = content[run].filter(\.token.echoed).count
            guard echoed >= minimumWords, Double(echoed) / Double(run.count) >= overlapShare,
                let firstSource = content[run.lowerBound].token.source,
                let lastSource = content[run.upperBound].token.source
            else { continue }
            var lower = content[run.lowerBound].unit
            var upper = content[run.upperBound].unit + 1
            // The short words the echo is made of go with it.
            while lower > 0, isEcho(units[lower - 1]) { lower -= 1 }
            while upper < units.count, isEcho(units[upper]) { upper += 1 }
            for count in (1...maximumLeftoverWords).reversed() where upper + count <= units.count {
                if misheard(units[upper..<upper + count], nextTo: lastSource, forward: true, theirs) {
                    upper += count
                    break
                }
            }
            for count in (1...maximumLeftoverWords).reversed() where lower - count >= 0 {
                if misheard(units[lower - count..<lower], nextTo: firstSource, forward: false, theirs) {
                    lower -= count
                    break
                }
            }
            removed.formUnion(lower..<upper)
        }
        return removed
    }

    private static func isEcho(_ unit: Unit) -> Bool {
        !unit.tokens.isEmpty && unit.tokens.allSatisfy(\.echoed)
    }

    /// Whether words beside a run are the microphone's mis-hearing of the
    /// remote words that come after (or before) the remote word the run's
    /// edge came from: they fall inside that line's span and are spelled almost
    /// as those words are, however the remote track's words are split between them.
    private static func misheard(
        _ units: ArraySlice<Unit>, nextTo source: Int, forward: Bool, _ theirs: RemoteWords
    ) -> Bool {
        let word = theirs.words[source]
        let span = theirs.lineSpans[word.line]
        guard
            units.allSatisfy({
                $0.start >= span.start - wordGapSeconds && $0.end <= span.end + wordGapSeconds
            })
        else { return false }
        let heard = Array(units.flatMap { $0.tokens.map(\.text) }.joined())
        guard heard.count >= minimumLetters else { return false }
        let line = theirs.lines[word.line]
        let beside = forward ? Array(line[(word.position + 1)...]) : Array(line[..<word.position])
        for count in max(1, units.count - 1)...(units.count + 1) where count <= beside.count {
            let ids = forward ? beside.prefix(count) : beside.suffix(count)
            let said = Array(ids.map { theirs.words[$0].text }.joined())
            let allowed = leftoverSpellingTolerance * Double(max(heard.count, said.count))
            if Double(editDistance(heard, said)) <= allowed { return true }
        }
        return false
    }

    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var row = Array(0...rhs.count)
        for (i, a) in lhs.enumerated() {
            var diagonal = row[0]
            row[0] = i + 1
            for (j, b) in rhs.enumerated() {
                let above = row[j + 1]
                row[j + 1] = min(row[j + 1] + 1, row[j] + 1, diagonal + (a == b ? 0 : 1))
                diagonal = above
            }
        }
        return row[rhs.count]
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

    /// Letters or digits a word needs to count toward a run. Shorter ones are
    /// the function words both sides say.
    static let minimumLetters = 3

    /// Backchannels. A person says them at any moment, so a match on one is no
    /// evidence of echo and a line made of them is the person's reply. Function
    /// words are not here: inside a run, matched one-to-one and in order, they
    /// are part of the echo, and leaving them out left runs of a few
    /// distinctive words under the minimum.
    static let ignoredWords: Set<String> = [
        "yes", "yeah", "yep", "yup", "okay", "right", "sure", "nope", "mhm", "uhhuh",
    ]

    /// Lowercased words of the text, without punctuation, which is the
    /// decoder's.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { $0.filter { $0 != "'" } }
            .filter { !$0.isEmpty }
    }
}
