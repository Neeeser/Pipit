import Foundation

/// The arithmetic behind the context window setting: what a window can hold,
/// and how much of a transcript to send in one request.
///
/// Every figure here is an estimate, and the constants are chosen to err toward
/// splitting early. A transcript that overflows a local model's window is cut
/// short without an error, which writes a summary of part of the meeting and
/// says nothing, so an estimate that is a little pessimistic costs one extra
/// request and an optimistic one costs a wrong answer.
public enum ContextWindow {
    /// The sizes the slider stops at.
    public static let sizes: [Int] = [4_096, 8_192, 16_384, 32_768, 65_536, 131_072, 262_144]

    /// The window for a model on this Mac. A meeting of about an hour fits, and
    /// the memory it costs is modest next to the model itself.
    public static let defaultTokens = 16_384
    public static let hostedDefaultTokens = 131_072

    /// Tokens a minute of conversation takes once it is written out as lines
    /// of "[time] Name: words". About 130 spoken words a minute at 1.3 tokens a
    /// word is 170, and the time and name on each line add roughly 40 more.
    public static let tokensPerMeetingMinute = 250

    /// Held back for the instructions, the folder list, the notes the person
    /// wrote, and the answer, none of which is transcript.
    public static let reservedTokens = 3_000

    /// English text runs near four characters to a token, and other languages
    /// run lower. This is the low end of that range for English.
    public static let charactersPerToken = 3.3

    public static func estimatedTokens(characters: Int) -> Int {
        Int((Double(max(characters, 0)) / charactersPerToken).rounded(.up))
    }

    /// How many characters of transcript one request can carry in a window.
    public static func transcriptCharacters(context tokens: Int, overheadCharacters: Int = 0) -> Int {
        let available = max(tokens - reservedTokens, 0) - estimatedTokens(characters: overheadCharacters)
        return max(minimumTranscriptCharacters, Int(Double(max(available, 0)) * charactersPerToken))
    }

    /// Below this a part carries too little to summarise, so a window this small
    /// is treated as this large and the request is the model's to refuse.
    public static let minimumTranscriptCharacters = 2_000

    /// Whole minutes of meeting a window holds.
    public static func meetingMinutes(context tokens: Int) -> Int {
        max(tokens - reservedTokens, 0) / tokensPerMeetingMinute
    }

    /// The window as a sentence fragment: "about 55 minutes", "about 4 hours".
    public static func fitDescription(context tokens: Int) -> String {
        let minutes = meetingMinutes(context: tokens)
        if minutes < 10 { return "under 10 minutes" }
        if minutes < 90 { return "about \(Int((Double(minutes) / 5).rounded()) * 5) minutes" }
        let hours = (Double(minutes) / 60 * 2).rounded() / 2
        let text = hours == hours.rounded() ? String(Int(hours)) : String(format: "%.1f", hours)
        return "about \(text) hours"
    }

    /// "16K", "128K", "1M".
    public static func label(_ tokens: Int) -> String {
        if tokens >= 1_048_576 { return "\(tokens / 1_048_576)M" }
        return "\(max(tokens / 1_024, 1))K"
    }

    /// A window a provider published, as people read it: 128,000 is "128K" and
    /// 1,048,576 is "1M". Unlike `label`, which names the slider's powers of
    /// two, this does not turn a round figure into an odd one.
    public static func publishedLabel(_ tokens: Int) -> String {
        if tokens >= 900_000 {
            let millions = (Double(tokens) / 1_000_000 * 10).rounded() / 10
            return millions == millions.rounded() ? "\(Int(millions))M" : String(format: "%.1fM", millions)
        }
        return "\(max(Int((Double(tokens) / 1_000).rounded()), 1))K"
    }

    /// The sizes a model can use: every size up to its own limit, and the limit
    /// itself when it falls between two. Never empty, so a model that reports
    /// nothing sensible still leaves a slider to move.
    public static func sizes(upTo maximum: Int?) -> [Int] {
        guard let maximum else { return sizes }
        guard maximum >= sizes[0] else { return [sizes[0]] }
        var available = sizes.filter { $0 <= maximum }
        if let last = available.last, maximum > last, maximum < sizes[sizes.count - 1] {
            available.append(maximum)
        }
        return available
    }

    /// The largest size that does not pass `limit`, for a model whose figure is
    /// known and should not be exceeded.
    public static func largestSize(atMost limit: Int) -> Int {
        sizes.last { $0 <= limit } ?? sizes[0]
    }

    /// The size nearest a stored value, so a hand-edited number lands somewhere
    /// the slider can show.
    public static func nearest(_ tokens: Int, in available: [Int]) -> Int {
        available.min { abs($0 - tokens) < abs($1 - tokens) } ?? defaultTokens
    }
}
