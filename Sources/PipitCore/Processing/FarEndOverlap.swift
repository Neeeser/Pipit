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
/// of them appear in far-end lines within `windowSeconds` of it. The bars are
/// set by the archive: across 22 cleaned meetings the rule removes 203 lines
/// on that call and 0 to 5 lines on every other one. A short reply stays,
/// because "sounds right" is what a person says back. A sentence with its own
/// words stays, because sharing a few nouns with the far end is a
/// conversation. The same words ten seconds later stay, because that is two
/// people.
public enum FarEndOverlap {
    /// Content words a line needs before it can be judged.
    public static let minimumWords = 4
    /// Share of them that have to be the far end's.
    public static let overlapShare = 0.6
    /// How far either side of the line the far end's words are looked for.
    public static let windowSeconds = 3.0

    public static func drop(_ utterances: [Utterance]) -> [Utterance] {
        let farEnd = utterances.filter { $0.track != .mic }
        guard !farEnd.isEmpty else { return utterances }
        return utterances.filter { utterance in
            guard utterance.track == .mic else { return true }
            return !isFarEnd(utterance, among: farEnd)
        }
    }

    static func isFarEnd(_ utterance: Utterance, among farEnd: [Utterance]) -> Bool {
        let own = contentWords(utterance.text)
        guard own.count >= minimumWords else { return false }
        let nearby = farEnd.filter {
            $0.end >= utterance.start - windowSeconds && $0.start <= utterance.end + windowSeconds
        }
        guard !nearby.isEmpty else { return false }
        let theirs = Set(nearby.flatMap { contentWords($0.text) })
        let shared = own.filter { theirs.contains($0) }.count
        return Double(shared) / Double(own.count) >= overlapShare
    }

    /// Lowercased words of three or more letters or digits. Shorter ones are
    /// the function words both sides say, and punctuation is the decoder's.
    static func contentWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { $0.filter { $0 != "'" } }
            .filter { $0.count >= 3 }
    }
}
