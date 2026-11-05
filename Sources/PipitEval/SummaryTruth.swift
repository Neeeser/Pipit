import Foundation
import PipitCore

/// One meeting's answer key for the summary evaluation, as committed under
/// `Benchmarks/summaries/truth`.
///
/// Written from the transcript by a model that is not one of those scored and
/// checked by hand. Items the corpus annotators also listed carry `mustFind`,
/// so a score can separate what any decent summary needs from thoroughness.
struct SummaryTruth: Codable, Sendable {
    struct ActionItem: Codable, Sendable {
        var task: String
        var owner: String
        var due: String
        var at: String
        var quote: String
        var mustFind: Bool

        enum CodingKeys: String, CodingKey {
            case task, owner, due, at, quote
            case mustFind = "must_find"
        }
    }

    struct Item: Codable, Sendable {
        var text: String
        var at: String
        var quote: String
        var mustFind: Bool

        enum CodingKeys: String, CodingKey {
            case text, at, quote
            case mustFind = "must_find"
        }
    }

    struct Topic: Codable, Sendable {
        var title: String
        var start: String
        var end: String
        var points: [String]
    }

    var meeting: String
    var overview: String
    var actionItems: [ActionItem]
    var decisions: [Item]
    var openQuestions: [Item]
    var topics: [Topic]

    enum CodingKeys: String, CodingKey {
        case meeting, overview, decisions, topics
        case actionItems = "action_items"
        case openQuestions = "open_questions"
    }
}

/// A meeting the evaluation runs: its transcript and its answer key.
struct SummaryCase: Sendable {
    struct Line: Sendable {
        var seconds: Double
        var speaker: String
        var text: String
    }

    var meeting: String
    var transcript: String
    var lines: [Line]
    var truth: SummaryTruth

    /// The speakers in the order they first talk.
    var participants: [String] {
        var seen: [String] = []
        for line in lines where !seen.contains(line.speaker) { seen.append(line.speaker) }
        return seen
    }

    /// The last line's start, which is as close to the length as the text says.
    var durationSeconds: Double { lines.last?.seconds ?? 0 }

    /// Every line start, for telling a time copied from the transcript from
    /// one the model made up.
    var lineStarts: Set<Double> { Set(lines.map(\.seconds)) }

    static func load(meeting: String, from directory: URL) throws -> SummaryCase {
        let transcript = try String(
            contentsOf: directory.appendingPathComponent("transcripts/\(meeting).txt"), encoding: .utf8
        )
        let truthData = try Data(contentsOf: directory.appendingPathComponent("truth/\(meeting).json"))
        let truth = try JSONDecoder().decode(SummaryTruth.self, from: truthData)
        let lines = transcript.split(separator: "\n").compactMap { raw -> Line? in
            guard raw.hasPrefix("["), let close = raw.firstIndex(of: "]"),
                let seconds = GeneratedSummary.seconds(fromTimecode: String(raw[...close])),
                let colon = raw[close...].firstIndex(of: ":")
            else { return nil }
            let speaker = raw[raw.index(after: close)..<colon].trimmingCharacters(in: .whitespaces)
            let text = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return Line(seconds: seconds, speaker: speaker, text: text)
        }
        return SummaryCase(meeting: meeting, transcript: transcript, lines: lines, truth: truth)
    }

    /// Every meeting with both a transcript and a truth file, by name.
    static func available(in directory: URL) -> [String] {
        let truths =
            (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("truth").path))
            ?? []
        return truths.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
            .filter {
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("transcripts/\($0).txt").path
                )
            }
            .sorted()
    }
}
