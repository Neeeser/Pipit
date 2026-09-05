import Foundation
import PipitCore
import Testing

/// Telling the summary and the generated notes apart again, on the way out of
/// one file.
@Suite("SummaryDocument")
struct SummaryDocumentTests {
    @Test("both sections come back separately")
    func bothSectionsComeBackSeparately() async throws {
        let document = SummaryDocument(
            markdown: "## Summary\n\nWe agreed on the pilot.\n\n## Notes\n\n- Chris sends the list."
        )
        #expect(document.summary == "We agreed on the pilot.")
        #expect(document.generatedNotes == "- Chris sends the list.")
    }

    @Test("a summary written without notes leaves the notes empty")
    func aSummaryWrittenWithoutNotesLeavesTheNotesEmpty() async throws {
        let document = SummaryDocument(markdown: "## Summary\n\nWe agreed on the pilot.")
        #expect(document.summary == "We agreed on the pilot.")
        #expect(document.generatedNotes == nil)
    }

    @Test("notes written without a summary read as notes")
    func notesWrittenWithoutASummaryReadAsNotes() async throws {
        // Notes on with summaries off is a real setting, so a file that
        // opens with the notes heading is a real file. It used to read
        // as the summary, which put the notes on the Summary tab with
        // the heading showing in the body.
        let document = SummaryDocument(markdown: "## Notes\n\n- Chris sends the list.")
        #expect(document.generatedNotes == "- Chris sends the list.")
        #expect(document.summary == nil)
    }

    @Test("a notes heading inside legacy prose is not a boundary")
    func aNotesHeadingInsideLegacyProseIsNotABoundary() async throws {
        // Only at the very start of the file. A summary written before
        // the split whose prose happens to mention the words is still
        // one summary, and moving half of it to another tab would be
        // worse than leaving the words where they are.
        let text = "We agreed on the pilot.\n\n## Notes were taken by Chris."
        #expect(SummaryDocument(markdown: text).summary == text)
    }

    @Test("a heading is only a heading when the line ends there")
    func aHeadingIsOnlyAHeadingWhenTheLineEndsThere() async throws {
        // A legacy summary can open with those words in a sentence. It
        // is a summary, and reading it as notes would put the whole
        // meeting on a tab the user has no reason to open.
        let text = "## Notes were taken by Chris and sent round afterwards."
        let document = SummaryDocument(markdown: text)
        #expect(document.summary == text)
        #expect(document.generatedNotes == nil)
    }

    @Test("a notes-only document round-trips")
    func aNotesOnlyDocumentRoundTrips() async throws {
        let original = SummaryDocument(generatedNotes: "- Chris sends the list.")
        #expect(SummaryDocument(markdown: original.markdown) == original)
    }

    @Test("a file with no heading reads as the summary")
    func aFileWithNoHeadingReadsAsTheSummary() async throws {
        // Every summary.md written before the split, and any a person
        // edited by hand. It has always shown on the Summary tab and
        // still does.
        let document = SummaryDocument(markdown: "Call with Capital One about retrieval.")
        #expect(document.summary == "Call with Capital One about retrieval.")
        #expect(document.generatedNotes == nil)
    }

    @Test("an empty file is an empty document")
    func anEmptyFileIsAnEmptyDocument() async throws {
        #expect(SummaryDocument(markdown: "").isEmpty)
        #expect(SummaryDocument(markdown: "   \n\n  ").isEmpty)
    }

    @Test("a heading with nothing under it is not a section")
    func aHeadingWithNothingUnderItIsNotASection() async throws {
        let document = SummaryDocument(markdown: "## Summary\n\n\n## Notes\n\n- One.")
        #expect(document.summary == nil, "an empty heading became an empty summary")
        #expect(document.generatedNotes == "- One.")
    }

    @Test("a heading inside the prose does not split the file")
    func aHeadingInsideTheProseDoesNotSplitTheFile() async throws {
        // The notes carry markdown of their own. Only the first notes
        // heading after the summary heading is a boundary.
        let document = SummaryDocument(
            markdown: "## Summary\n\nWe agreed.\n\n## Notes\n\n- One.\n\n## Notes\n\n- Two."
        )
        #expect(document.summary == "We agreed.")
        #expect(document.generatedNotes == "- One.\n\n## Notes\n\n- Two.")
    }

    @Test("what enrichment writes reads back unchanged")
    func whatEnrichmentWritesReadsBackUnchanged() async throws {
        let original = SummaryDocument(
            summary: "We agreed on the pilot.", generatedNotes: "- Chris sends the list."
        )
        #expect(SummaryDocument(markdown: original.markdown) == original)
    }

}
