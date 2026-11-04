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

    @Test("a structure saved before questions were flagged still reads")
    func aStructureSavedBeforeQuestionsWereFlaggedStillReads() throws {
        let item = #"{"task":"Do it","owner":"","due":""}"#
        let saved = #"{"overview":"","topics":[{"title":"T","points":[],"actionItems":["# + item + "]}]}"
        let summary = try JSONDecoder().decode(GeneratedSummary.self, from: Data(saved.utf8))
        #expect(summary.actionItems == [GeneratedSummary.ActionItem(task: "Do it")])
    }

    @Test("timed notes are placed in the meeting, and other lines are notes without a time")
    func timedNotesArePlacedInTheMeeting() throws {
        let started = try #require(ISO8601DateFormatter().date(from: "2026-11-03T15:00:00Z"))
        let notes = """
            - [2026-11-03T15:05:42.250Z] check the web app too

            Send the tester list before Thursday
            - [2026-11-03T14:59:50Z] typed before it started
            - [not a time] kept as written
            """
        #expect(
            MeetingNoteEntry.entries(in: notes, startedAt: started) == [
                MeetingNoteEntry(text: "check the web app too", at: 342.25),
                MeetingNoteEntry(text: "Send the tester list before Thursday"),
                MeetingNoteEntry(text: "typed before it started", at: 0),
                MeetingNoteEntry(text: "[not a time] kept as written"),
            ])
    }

    @Test("a partly wrong answer keeps what is usable")
    func aPartlyWrongAnswerKeepsWhatIsUsable() {
        let answer: [String: Any] = [
            "overview": "They agreed to ship.",
            "topics": [
                [
                    "title": "Release", "at": "[00:01]", "points": ["Friday", ""],
                    "action_items": [
                        ["task": "Write the notes", "owner": "Ana", "due": "", "at": "00:03", "question": false],
                        ["task": "Ana", "owner": "Ana", "due": "", "at": "00:04", "question": false],
                        ["task": "write the notes", "owner": "Ana", "due": "", "at": "00:05", "question": false],
                        // A small model in JSON mode writes the flag as a
                        // string, or leaves it out.
                        [
                            "task": "Find out who tells support", "owner": "", "due": "", "at": "00:06",
                            "question": "true",
                        ],
                        ["task": "Call the client", "owner": "", "due": "", "at": "99:00"],
                    ],
                ],
                ["title": "", "at": "", "points": [], "action_items": []],
            ],
        ]
        let summary = LanguageModelPrompts.generatedSummary(from: answer, durationSeconds: 600)
        #expect(summary.topics.count == 1, "a topic with nothing in it is dropped")
        let topic = summary.topics[0]
        #expect(topic.at == 1, "a time copied with its brackets still reads")
        #expect(topic.points == ["Friday"])
        #expect(topic.actionItems.map(\.task) == ["Write the notes", "Find out who tells support", "Call the client"])
        #expect(topic.actionItems.map(\.isQuestion) == [false, true, false])
        #expect(topic.actionItems.last?.at == nil, "a time past the end of the meeting is dropped, the task kept")
        #expect(LanguageModelPrompts.acceptsEnrichment(answer, for: request(title: false)))
    }

    @Test("the summary and the notes are written from the structure for summary.md")
    func theSummaryAndNotesAreWrittenFromTheStructure() {
        let answer: [String: Any] = [
            "overview": "They agreed to ship.", "title": "Release",
            "topics": [
                [
                    "title": "Release", "at": "00:01", "points": ["Friday is the date"],
                    "action_items": [
                        [
                            "task": "Write the notes", "owner": "Ana", "due": "Thursday", "at": "00:03",
                            "question": false,
                        ]
                    ],
                ]
            ],
        ]
        let result = LanguageModelPrompts.enrichment(from: answer, for: request())
        #expect(
            result.summary == """
                They agreed to ship.

                ### Action items

                - Write the notes (Ana, due Thursday) [00:03]
                """)
        #expect(result.notes == "### Release [00:01]\n\n- Friday is the date")

        let notesOnly = LanguageModelPrompts.enrichment(from: answer, for: request(summary: false))
        #expect(notesOnly.summary == nil)
        #expect(notesOnly.notes != nil)
    }
}
