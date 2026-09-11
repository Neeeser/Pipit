import Foundation

/// Divides a line where the other track starts speaking, so the transcript
/// reads in the order people spoke.
///
/// A decoder cuts its segments at pauses in one person's audio: one second of
/// silence, or thirty seconds of talk. Somebody talking without a pause for
/// thirty seconds arrives as one line, and the transcript is sorted by line
/// start, so every reply the far end made inside those thirty seconds printed
/// after the whole block. Measured over one day's meetings: 9 of 90 lines in
/// one call and 32 of 142 in another held a reply that started more than a
/// second in.
///
/// A line divides at the first word starting after the reply, unless a
/// sentence ends within `sentenceSnapSeconds` past that moment, in which case
/// it divides there and the sentence stays whole. The division never moves
/// back: the transcript is sorted by start, so a piece that began before the
/// reply would print before it and hide it again. A line whose words were
/// never timed is left as it is, because nothing on it says where a word
/// begins.
///
/// One round, against the lines as assembled. A piece can itself start inside
/// a line on the other track, which only happens when both tracks carry
/// continuous words through the same stretch, and dividing again there
/// alternates the two down to a word apiece. Two people talking at once have
/// no reading order, and one block after the other reads better than that.
public enum TurnInterleaving {
    /// How far forward a division may move to land on a sentence end. A
    /// backchannel spoken over the last words of a sentence reads better after
    /// it.
    public static let sentenceSnapSeconds = 2.0

    public static func apply(_ utterances: [Utterance]) -> [Utterance] {
        utterances.flatMap { utterance in
            let cuts = divisions(of: utterance, among: utterances)
            guard !cuts.isEmpty else { return [utterance] }
            return LineDivision.divide(
                utterance,
                at: cuts.map {
                    LineCut(
                        track: utterance.track, atSeconds: $0, chunkID: utterance.chunkID,
                        createdAt: Date(timeIntervalSince1970: 0)
                    )
                })
        }
    }

    /// The moments this line divides at, one per line on another track that
    /// starts strictly inside it.
    private static func divisions(of utterance: Utterance, among others: [Utterance]) -> [Double] {
        guard let words = utterance.words, words.count > 1 else { return [] }
        let starts = others.lazy
            .filter { $0.track != utterance.track }
            .map(\.start)
            .filter { $0 > utterance.start && $0 < utterance.end }
            .sorted()
        var moments: [Double] = []
        for (index, start) in starts.enumerated() {
            // The next reply owns everything from its own start. A division
            // for this one that reached that far would open a piece starting
            // with the next reply, and the sort would put the piece first.
            let limit = starts[(index + 1)...].first { $0 > start }
            if let moment = division(in: words, after: start, before: limit) {
                moments.append(moment)
            }
        }
        return moments
    }

    /// The start of the word the line divides before, or nil where no word
    /// starts after the reply and before the limit.
    ///
    /// Strictly after. A word starting at the same instant as the reply would
    /// open a piece that ties with the reply on start, and the sort settles a
    /// tie by track, which put the continuation back in front of the reply.
    private static func division(
        in words: [RawTranscriptWord], after seconds: Double, before limit: Double?
    ) -> Double? {
        func allowed(_ start: Double) -> Bool {
            start > seconds && limit.map { start < $0 } ?? true
        }
        // The first word after a sentence end, within the band past the
        // reply. The first such word is the closest, and it keeps the
        // sentence the reply interrupted whole.
        let snapped = words.indices.dropFirst().first { index in
            allowed(words[index].start)
                && words[index].start - seconds <= sentenceSnapSeconds
                && endsSentence(words[index - 1].text)
        }
        if let snapped { return words[snapped].start }
        guard let nearest = words.firstIndex(where: { allowed($0.start) }), nearest > 0 else {
            return nil
        }
        return words[nearest].start
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return last == "." || last == "?" || last == "!"
    }
}
