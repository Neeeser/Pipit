import Foundation
import PipitCore
import Testing

@testable import PipitIntegrations

/// The summary and notes a model writes, from the request it is sent to the
/// structure read back out of its answer.
@Suite("GeneratedSummary")
struct GeneratedSummaryTests {
    private func request(
        summary: Bool = true, notes: Bool = true, title: Bool = true, source: EnrichmentSource = .transcript,
        startedAt: Date? = nil
    ) -> EnrichmentRequest {
        EnrichmentRequest(
            transcript: "[00:01] Ana: We ship on Friday.", humanNotes: nil, participants: ["Ana"],
            provider: .zoom, durationSeconds: 600, wantsTitle: title, wantsDescription: false,
            wantsSummary: summary, wantsNotes: notes, source: source, startedAt: startedAt
        )
    }

    private func schemaKeys(_ prompt: LanguageModelPrompt) throws -> [String] {
        let properties = try #require(prompt.schema["properties"] as? OrderedJSONObject)
        return properties.pairs.map(\.0)
    }

    @Test("times read as a transcript line writes them, brackets or not")
    func timesReadAsATranscriptLineWritesThem() {
        #expect(GeneratedSummary.seconds(fromTimecode: "12:04") == 724)
        #expect(GeneratedSummary.seconds(fromTimecode: "[1:02:03]") == 3_723)
        #expect(GeneratedSummary.seconds(fromTimecode: " [00:09] ") == 9)
        #expect(GeneratedSummary.seconds(fromTimecode: "12:75") == nil)
        #expect(GeneratedSummary.seconds(fromTimecode: "") == nil)
        #expect(GeneratedSummary.seconds(fromTimecode: "twelve") == nil)
    }

    @Test("the topics are asked for before the overview, so the overview comes last")
    func theTopicsAreAskedForBeforeTheOverview() throws {
        let prompt = try #require(LanguageModelPrompts.enrichment(request()))
        #expect(try schemaKeys(prompt) == ["topics", "overview", "title"])
    }

    @Test("the request that combines a long meeting's parts asks only for the overview")
    func theCombiningRequestAsksOnlyForTheOverview() throws {
        let combining = request(source: .partNotes(parts: 3))
        let prompt = try #require(LanguageModelPrompts.enrichment(combining))
        #expect(try schemaKeys(prompt) == ["overview", "title"])
        #expect(LanguageModelPrompts.acceptsEnrichment(["overview": "Done.", "title": "T"], for: combining))
    }

    @Test("the summary instructions hold no sample values for a model to copy")
    func theSummaryInstructionsHoldNoSampleValues() {
        // A small model copied a sample deadline onto nearly every task and a
        // sample decision into its decisions, so the instructions describe each
        // field and give no example of one.
        let instructions = LanguageModelPrompts.writeupInstructions
        #expect(!instructions.contains("\""))
        #expect(instructions.rangeOfCharacter(from: .decimalDigits) == nil)
    }

    @Test("the meeting date is sent, so a deadline said as a weekday can be read")
    func theMeetingDateIsSent() throws {
        let started = try #require(ISO8601DateFormatter().date(from: "2026-11-02T15:00:00Z"))
        let prompt = try #require(LanguageModelPrompts.enrichment(request(startedAt: started)))
        #expect(prompt.userContent.contains("Meeting date: Monday, November 2, 2026."))
    }

    @Test("an instructions override replaces the built-in summary instructions")
    func anInstructionsOverrideReplacesTheBuiltInOnes() throws {
        var draft = request()
        draft.instructions = "A draft of the instructions."
        let prompt = try #require(LanguageModelPrompts.enrichment(draft))
        #expect(prompt.instructions.hasPrefix("A draft of the instructions."))
        #expect(!prompt.instructions.contains(LanguageModelPrompts.writeupInstructions))
    }

    @Test("a partly wrong answer keeps what is usable")
    func aPartlyWrongAnswerKeepsWhatIsUsable() {
        let answer: [String: Any] = [
            "overview": "They agreed to ship.",
            "topics": [
                [
                    "title": "Release", "at": "00:01", "points": ["Friday", ""],
                    "decisions": [["text": "Ship on Friday", "at": "[00:01]"], ["text": "  ", "at": "00:02"]],
                    "action_items": [
                        ["task": "Write the notes", "owner": "Ana", "due": "", "at": "00:03"],
                        ["task": "Ana", "owner": "Ana", "due": "", "at": "00:04"],
                        ["task": "write the notes", "owner": "Ana", "due": "", "at": "00:05"],
                        ["task": "Call the client", "owner": "", "due": "", "at": "99:00"],
                    ],
                    // No open_questions: a model in JSON mode leaves out an
                    // empty list, and an empty list is what it meant.
                ],
                ["title": "", "at": "", "points": [], "decisions": [], "action_items": [], "open_questions": []],
            ],
        ]
        let summary = LanguageModelPrompts.generatedSummary(from: answer, durationSeconds: 600)
        #expect(summary.topics.count == 1, "a topic with nothing in it is dropped")
        let topic = summary.topics[0]
        #expect(topic.points == ["Friday"])
        #expect(topic.decisions == [GeneratedSummary.Item(text: "Ship on Friday", at: 1)])
        #expect(topic.actionItems.map(\.task) == ["Write the notes", "Call the client"])
        #expect(topic.actionItems.last?.at == nil, "a time past the end of the meeting is dropped, the task kept")
        #expect(topic.openQuestions.isEmpty)
        #expect(LanguageModelPrompts.acceptsEnrichment(answer, for: request(title: false)))
    }

    @Test("the summary and the notes are written from the structure for summary.md")
    func theSummaryAndNotesAreWrittenFromTheStructure() {
        let answer: [String: Any] = [
            "overview": "They agreed to ship.", "title": "Release",
            "topics": [
                [
                    "title": "Release", "at": "00:01", "points": ["Friday is the date"],
                    "decisions": [["text": "Ship on Friday", "at": "00:01"]],
                    "action_items": [["task": "Write the notes", "owner": "Ana", "due": "Thursday", "at": "00:03"]],
                    "open_questions": [["text": "Who tells support?", "at": "00:05"]],
                ]
            ],
        ]
        let result = LanguageModelPrompts.enrichment(from: answer, for: request())
        #expect(
            result.summary == """
                They agreed to ship.

                ### Action items

                - Write the notes (Ana, due Thursday) [00:03]

                ### Decisions

                - Ship on Friday [00:01]

                ### Open questions

                - Who tells support? [00:05]
                """)
        #expect(result.notes == "### Release [00:01]\n\n- Friday is the date")

        let notesOnly = LanguageModelPrompts.enrichment(from: answer, for: request(summary: false))
        #expect(notesOnly.summary == nil)
        #expect(notesOnly.notes != nil)
    }
}
