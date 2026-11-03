import Foundation
import PipitCore
import PipitIntegrations

/// Grades the parts of a summary that matching cannot: whether the overview
/// does its job, whether each note is true to the transcript, whether the notes
/// cover each topic the key lists, and whether an item the key lacks was said
/// or made up.
///
/// The judge's model is fixed per run and written into every result, with the
/// version of these instructions, so scores from two judges are never compared
/// as if they were one.
struct SummaryJudge {
    /// Raise when the instructions or the schema change, so old scores are
    /// recognisably from a different judge.
    static let version = 1

    static let instructions = """
        You check meeting notes that a model wrote from a transcript, for a tool that \
        compares models. Your answers are counted, so judge each thing on its own and \
        answer from the transcript, not from what seems likely.

        overview: answer each question about the model's overview. why_they_met and \
        where_it_landed and what_happens_next ask whether the overview says that at all. \
        all_true asks whether everything it says matches the transcript.

        points: for each numbered note, whether the transcript supports it. A note that \
        gets a figure, a person or an outcome wrong is not supported.

        key_topics: for each numbered topic from a reference set of notes, whether the \
        model's notes cover what was said about it, in any wording or under any heading. \
        Covering means a reader of the model's notes would know the substance, not only \
        that the subject came up.

        unmatched: these are action items, decisions and open questions the model listed \
        that matched nothing in the reference. For each, say real when the transcript \
        shows it was said or agreed as the model states it, and invented when it was not, \
        including when the model turned a suggestion into a decision or gave a task to \
        the wrong person.
        """

    struct Verdict: Codable, Sendable {
        struct Overview: Codable, Sendable {
            var whyTheyMet: Bool
            var whereItLanded: Bool
            var whatHappensNext: Bool
            var allTrue: Bool

            enum CodingKeys: String, CodingKey {
                case whyTheyMet = "why_they_met"
                case whereItLanded = "where_it_landed"
                case whatHappensNext = "what_happens_next"
                case allTrue = "all_true"
            }

            /// The share of the four checks passed, with a false statement
            /// failing the whole overview.
            var score: Double {
                guard allTrue else { return 0 }
                return Double([whyTheyMet, whereItLanded, whatHappensNext].filter { $0 }.count + 1) / 4
            }
        }

        struct Point: Codable, Sendable {
            var id: Int
            var supported: Bool
        }

        struct KeyTopic: Codable, Sendable {
            var id: Int
            var covered: Bool
        }

        struct Unmatched: Codable, Sendable {
            var id: Int
            var verdict: String
        }

        var overview: Overview
        var points: [Point]
        var keyTopics: [KeyTopic]
        var unmatched: [Unmatched]

        enum CodingKeys: String, CodingKey {
            case overview, points, unmatched
            case keyTopics = "key_topics"
        }
    }

    /// An item the matcher could not pair, numbered for the judge.
    struct UnmatchedItem: Codable, Sendable {
        var kind: String
        var text: String
        var owner: String?
    }

    let client: any StructuredLanguageModel
    let model: String

    func judge(
        meeting: SummaryCase, summary: GeneratedSummary, unmatched: [UnmatchedItem]
    ) async throws -> Verdict {
        var content = "Transcript:\n\(meeting.transcript)\n"
        content += "\nThe model's overview:\n\(summary.overview.isEmpty ? "(none)" : summary.overview)\n"
        content += "\nThe model's notes, numbered:\n"
        var number = 0
        for topic in summary.topics {
            content += "\(topic.title)\n"
            for point in topic.points {
                number += 1
                content += "  \(number). \(point)\n"
            }
        }
        if number == 0 { content += "(none)\n" }
        content += "\nReference topics, numbered:\n"
        for (index, topic) in meeting.truth.topics.enumerated() {
            content += "\(index + 1). \(topic.title): \(topic.points.joined(separator: " "))\n"
        }
        content += "\nUnmatched items, numbered:\n"
        for (index, item) in unmatched.enumerated() {
            let owner = item.owner.map { $0.isEmpty ? " (no owner)" : " (owner: \($0))" } ?? ""
            content += "\(index + 1). [\(item.kind)] \(item.text)\(owner)\n"
        }
        if unmatched.isEmpty { content += "(none)\n" }

        let flag: [String: Any] = ["type": "boolean"]
        let numbered = { (name: String, value: [String: Any]) in
            ["type": "array", "items": LanguageModelPrompt.object([("id", ["type": "integer"]), (name, value)])]
                as [String: Any]
        }
        let schema = LanguageModelPrompt.object([
            (
                "overview",
                LanguageModelPrompt.object([
                    ("why_they_met", flag), ("where_it_landed", flag), ("what_happens_next", flag),
                    ("all_true", flag),
                ])
            ),
            ("points", numbered("supported", flag)),
            ("key_topics", numbered("covered", flag)),
            ("unmatched", numbered("verdict", ["type": "string", "enum": ["real", "invented"]])),
        ])
        let prompt = LanguageModelPrompt(
            instructions: Self.instructions, userContent: content, schemaName: "summary_judgement", schema: schema
        )
        let data = try await client.structuredAnswer(prompt, model: model)
        return try JSONDecoder().decode(Verdict.self, from: data)
    }
}
