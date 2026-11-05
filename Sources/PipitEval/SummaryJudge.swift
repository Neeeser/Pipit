import Foundation
import PipitCore
import PipitIntegrations

/// Grades the parts of a summary that embeddings cannot: whether a proposed
/// pair really says the same thing, whether each item the model listed was
/// said, whether the overview does its job, whether each note is true to the
/// transcript, and whether the notes cover each topic the key lists.
///
/// The judge's model is fixed per run and written into every result, with the
/// version of these instructions, so scores from two judges are never compared
/// as if they were one.
struct SummaryJudge: Sendable {
    /// Raise when the instructions or the schema change, so old scores are
    /// recognisably from a different judge.
    static let version = 3

    static let instructions = """
        You check meeting notes that a model wrote from a transcript, for a tool that \
        compares models. Your answers are counted, so judge each thing on its own and \
        answer from the transcript, not from what seems likely.

        pairs: each numbered pair holds an item from a reference set of notes and an item \
        the model wrote. same is true when the model's item states the same task or question \
        as the reference item, in any wording and even with less detail. It is \
        false when they share a subject but say different or opposite things, or name a \
        different task.

        items: for each numbered item the model listed, real when the transcript shows it \
        was said or agreed as the model states it, and invented when it was not, including \
        when the model turned a suggestion into a commitment or gave a task to the wrong \
        person.

        overview: why_they_met, where_it_landed and what_happens_next ask whether the \
        model's overview says that at all. all_true asks whether everything it says \
        matches the transcript.

        points: for each numbered note, whether the transcript supports it. A note that \
        gets a figure, a person or an outcome wrong is not supported.

        key_topics: for each numbered reference topic, whether the model's notes cover what \
        was said about it, in any wording or under any heading. Covering means a reader of \
        the model's notes would know the substance, not only that the subject came up.
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

        struct Numbered: Codable, Sendable {
            var id: Int
            var yes: Bool
        }

        var overview: Overview
        var pairs: [Numbered]
        var items: [Numbered]
        var points: [Numbered]
        var keyTopics: [Numbered]

        enum CodingKeys: String, CodingKey {
            case overview, pairs, items, points
            case keyTopics = "key_topics"
        }

        /// Whether the numbered thing was answered yes; nil when the judge
        /// skipped it.
        static func answer(_ list: [Numbered], _ number: Int) -> Bool? {
            list.first { $0.id == number }?.yes
        }
    }

    /// One thing the model listed, as the judge is shown it.
    struct Item: Codable, Sendable {
        var kind: String
        var text: String
        var owner: String?
    }

    /// A key item and a model item the embeddings proposed as the same.
    struct ProposedPair: Codable, Sendable {
        var kind: String
        var key: String
        var model: String
    }

    let client: any StructuredLanguageModel
    let model: String

    /// What the judge is shown. Verdicts are filed under a hash of it, so a
    /// change to the matching never reuses a verdict on different input.
    static func content(
        meeting: SummaryCase, summary: GeneratedSummary, pairs: [ProposedPair], items: [Item]
    ) -> String {
        var content = "Transcript:\n\(meeting.transcript)\n"
        content += "\nPairs, numbered:\n"
        for (index, pair) in pairs.enumerated() {
            content += "\(index + 1). [\(pair.kind)]\n   reference: \(pair.key)\n   model: \(pair.model)\n"
        }
        if pairs.isEmpty { content += "(none)\n" }
        content += "\nItems the model listed, numbered:\n"
        for (index, item) in items.enumerated() {
            let owner = item.owner.map { $0.isEmpty ? " (no owner)" : " (owner: \($0))" } ?? ""
            content += "\(index + 1). [\(item.kind)] \(item.text)\(owner)\n"
        }
        if items.isEmpty { content += "(none)\n" }
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
        return content
    }

    func judge(content: String) async throws -> Verdict {
        let flag: [String: Any] = ["type": "boolean"]
        let numbered = { (name: String) in
            ["type": "array", "items": LanguageModelPrompt.object([("id", ["type": "integer"]), (name, flag)])]
                as [String: Any]
        }
        let schema = LanguageModelPrompt.object([
            ("pairs", numbered("same")),
            ("items", numbered("real")),
            (
                "overview",
                LanguageModelPrompt.object([
                    ("why_they_met", flag), ("where_it_landed", flag), ("what_happens_next", flag),
                    ("all_true", flag),
                ])
            ),
            ("points", numbered("supported")),
            ("key_topics", numbered("covered")),
        ])
        let prompt = LanguageModelPrompt(
            instructions: Self.instructions, userContent: content, schemaName: "summary_judgement", schema: schema
        )
        let data = try await client.structuredAnswer(prompt, model: model)
        // Each list names its answer for what it asks; read them all as yes.
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SummaryEmbedder.Failure(message: "the judge did not answer with an object")
        }
        for (list, name) in [("pairs", "same"), ("items", "real"), ("points", "supported"), ("key_topics", "covered")] {
            object[list] = ((object[list] as? [[String: Any]]) ?? []).map {
                ["id": $0["id"] ?? 0, "yes": $0[name] ?? false]
            }
        }
        return try JSONDecoder().decode(Verdict.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
