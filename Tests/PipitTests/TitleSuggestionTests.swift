import Foundation
import PipitCore
import Testing

/// When the generated title is offered to the user, and when it is not.
///
/// A generated title exists on nearly every processed meeting, so the rule
/// deciding which of them ask a question is the whole feature.
@Suite("Title suggestions")
struct TitleSuggestionTests {
    private static func metadata(_ titles: TitleCandidates) -> MeetingMetadata {
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        return MeetingMetadata(
            id: "m1", source: .slackHuddle, provider: .slack,
            createdAt: started, startedAt: started, titles: titles
        )
    }

    @Test("a meeting named by its huddle is offered the generated title")
    func aMeetingNamedByItsHuddleIsOfferedTheGeneratedTitle() async throws {
        var titles = TitleCandidates(timestampFallback: "f")
        titles.provider = "Huddle in #engineering"
        titles.ai = "Pricing model rework"
        #expect(Self.metadata(titles).titleSuggestion == "Pricing model rework")
    }

    @Test("a meeting named by a calendar event is offered it too")
    func aMeetingNamedByACalendarEventIsOfferedItToo() async throws {
        var titles = TitleCandidates(timestampFallback: "f")
        titles.calendar = "Weekly sync"
        titles.ai = "Pricing model rework"
        #expect(Self.metadata(titles).titleSuggestion == "Pricing model rework")
    }

    @Test("an imported file is offered it against its filename")
    func anImportedFileIsOfferedItAgainstItsFilename() async throws {
        var titles = TitleCandidates(timestampFallback: "f")
        titles.filename = "Board meeting Aug 12"
        titles.ai = "Quarterly financial review"
        #expect(Self.metadata(titles).titleSuggestion == "Quarterly financial review")
    }

    @Test("nothing is offered when the generated title already won")
    func nothingIsOfferedWhenTheGeneratedTitleAlreadyWon() async throws {
        var titles = TitleCandidates(timestampFallback: "f")
        titles.window = "Meet - abc-defg-hij"
        titles.ai = "Pricing model rework"
        #expect(titles.resolvedOrigin == "ai")
        #expect(Self.metadata(titles).titleSuggestion == nil)
    }

    @Test("nothing is offered once the user has named it themselves")
    func nothingIsOfferedOnceTheUserHasNamedItThemselves() async throws {
        var titles = TitleCandidates(timestampFallback: "f")
        titles.provider = "Huddle in #engineering"
        titles.ai = "Pricing model rework"
        titles.human = "Renewal call"
        #expect(Self.metadata(titles).titleSuggestion == nil)
    }

    @Test("nothing is offered when no title was generated")
    func nothingIsOfferedWhenNoTitleWasGenerated() async throws {
        var titles = TitleCandidates(timestampFallback: "f")
        titles.provider = "Huddle in #engineering"
        #expect(Self.metadata(titles).titleSuggestion == nil)
        titles.ai = "   "
        #expect(Self.metadata(titles).titleSuggestion == nil)
    }

    @Test("nothing is offered when it only differs by case")
    func nothingIsOfferedWhenItOnlyDiffersByCase() async throws {
        var titles = TitleCandidates(timestampFallback: "f")
        titles.provider = "Pricing model rework"
        titles.ai = "Pricing Model Rework"
        #expect(Self.metadata(titles).titleSuggestion == nil)
    }

    @Test("nothing is offered when only stray whitespace separates them")
    func nothingIsOfferedWhenOnlyStrayWhitespaceSeparatesThem() async throws {
        var titles = TitleCandidates(timestampFallback: "f")
        titles.provider = "Pricing model rework  "
        titles.ai = "Pricing model rework"
        #expect(Self.metadata(titles).titleSuggestion == nil)
    }

    @Test("declining settles it, and leaves the generated title on disk")
    func decliningSettlesItAndLeavesTheGeneratedTitleOnDisk() async throws {
        var titles = TitleCandidates(timestampFallback: "f")
        titles.provider = "Huddle in #engineering"
        titles.ai = "Pricing model rework"
        var found = Self.metadata(titles)
        #expect(found.titleSuggestion != nil)

        found.generatedTitleDeclined = true
        #expect(found.titleSuggestion == nil)
        // The fallback survives: clearing a title of their own later
        // still lands on the generated one rather than a timestamp.
        #expect(found.titles.ai == "Pricing model rework")
        found.titles.provider = nil
        #expect(found.displayTitle == "Pricing model rework")
    }

    @Test("accepting outranks the name it was offered against")
    func acceptingOutranksTheNameItWasOfferedAgainst() async throws {
        var titles = TitleCandidates(timestampFallback: "f")
        titles.provider = "Huddle in #engineering"
        titles.ai = "Pricing model rework"
        var found = Self.metadata(titles)
        let suggestion = found.titleSuggestion
        #expect(suggestion == "Pricing model rework")

        // What the runtime writes on Use it.
        found.titles.human = suggestion
        #expect(found.displayTitle == "Pricing model rework")
        #expect(found.titleSuggestion == nil, "and the offer is gone")
        #expect(
            MeetingFolderName.base(for: found) == "Pricing model rework (\(MeetingFolderName.stamp(found.startedAt)))",
            "so the folder follows"
        )
    }

}
