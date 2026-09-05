import Foundation
import PipitCore
import Testing

@Suite("Meeting folder names")
struct MeetingFolderNameTests {
    /// Built through `Calendar.current` so the expected stamp holds in any
    /// timezone the tests run in.
    static func date(
        year: Int, month: Int, day: Int, hour: Int, minute: Int
    ) -> Date {
        Calendar.current.date(
            from: DateComponents(
                year: year, month: month, day: day, hour: hour, minute: minute
            )
        ) ?? Date(timeIntervalSince1970: 0)
    }

    @Test("a title leads and the date follows")
    func aTitleLeadsAndTheDateFollows() async throws {
        let name = MeetingFolderName.base(
            title: "Pricing model rework",
            source: .googleMeet,
            startedAt: Self.date(year: 2026, month: 8, day: 18, hour: 14, minute: 18)
        )
        #expect(name == "Pricing model rework (Aug 18, 2:18 PM)")
    }

    @Test("the day is padded so a series sorts by date")
    func theDayIsPaddedSoASeriesSortsByDate() async throws {
        let third = MeetingFolderName.base(
            title: "Northwind Daily",
            source: .slackHuddle,
            startedAt: Self.date(year: 2026, month: 8, day: 3, hour: 9, minute: 2)
        )
        let eighteenth = MeetingFolderName.base(
            title: "Northwind Daily",
            source: .slackHuddle,
            startedAt: Self.date(year: 2026, month: 8, day: 18, hour: 9, minute: 0)
        )
        #expect(third == "Northwind Daily (Aug 03, 9:02 AM)")
        #expect(third < eighteenth, "\(third) should sort before \(eighteenth)")
    }

    @Test("midnight and noon read as 12")
    func midnightAndNoonReadAs12() async throws {
        #expect(MeetingFolderName.stamp(
                Self.date(year: 2026, month: 1, day: 1, hour: 0, minute: 5)
            ) == "Jan 01, 12:05 AM")
        #expect(MeetingFolderName.stamp(
                Self.date(year: 2026, month: 12, day: 31, hour: 12, minute: 0)
            ) == "Dec 31, 12:00 PM")
    }

    @Test("path-breaking characters are replaced and the rest survives")
    func pathBreakingCharactersAreReplacedAndTheRestSurvives() async throws {
        let name = MeetingFolderName.base(
            title: "Q3/Q4 planning: Café \u{1F389}\nreview",
            source: .zoom,
            startedAt: Self.date(year: 2026, month: 8, day: 18, hour: 14, minute: 18)
        )
        #expect(!name.contains("/"), "got \(name)")
        #expect(!(name.contains(":") && !name.contains(", 2:18")), "got \(name)")
        #expect(!name.contains("\n"), "got \(name)")
        #expect(name.contains("Café"), "accents should survive, got \(name)")
        #expect(name.contains("\u{1F389}"), "emoji should survive, got \(name)")
        #expect(name.hasSuffix("(Aug 18, 2:18 PM)"), "got \(name)")
    }

    @Test("a long title is cut at a word boundary")
    func aLongTitleIsCutAtAWordBoundary() async throws {
        let title = String(repeating: "alpha bravo ", count: 12)
        let name = MeetingFolderName.base(
            title: title,
            source: .manual,
            startedAt: Self.date(year: 2026, month: 8, day: 18, hour: 14, minute: 18)
        )
        let head = String(name.prefix(while: { $0 != "(" }))
            .trimmingCharacters(in: .whitespaces)
        #expect(head.count <= 60, "got \(head.count): \(head)")
        #expect(!head.hasSuffix(" "), "got \(head)")
        #expect(
            head.hasSuffix("alpha") || head.hasSuffix("bravo"),
            "should end on a whole word, got \(head)"
        )
    }

    @Test("a name of multi-byte characters still fits a path component")
    func aNameOfMultiByteCharactersStillFitsAPathComponent() async throws {
        // 60 characters of emoji is 240 bytes before the date is added,
        // and NAME_MAX is 255, so capping on characters alone made
        // createMeeting throw and the recording never start.
        let name = MeetingFolderName.base(
            title: String(repeating: "\u{1F389}", count: 200),
            source: .zoom,
            startedAt: Self.date(year: 2026, month: 8, day: 18, hour: 14, minute: 18)
        )
        #expect(name.utf8.count <= 255, "got \(name.utf8.count) bytes")
        #expect(name.hasSuffix("(Aug 18, 2:18 PM)"), "got \(name)")

        let cjk = MeetingFolderName.base(
            title: String(repeating: "\u{4F1A}\u{8B70}", count: 60),
            source: .zoom,
            startedAt: Self.date(year: 2026, month: 8, day: 18, hour: 14, minute: 18)
        )
        #expect(cjk.utf8.count <= 255, "got \(cjk.utf8.count) bytes")
    }

    @Test("a generated title beats a window title and loses to a meeting's own")
    func aGeneratedTitleBeatsAWindowTitleAndLosesToAMeetingSOwn() async throws {
        var titles = TitleCandidates(timestampFallback: "fallback")
        titles.window = "Meet - abc-defg-hij"
        titles.ai = "Pricing model rework"
        #expect(titles.resolved == "Pricing model rework")
        #expect(titles.resolvedOrigin == "ai")

        // What the people in the meeting call it wins, so a recurring
        // meeting keeps one name across every instance.
        titles.calendar = "Northwind Daily"
        #expect(titles.resolved == "Northwind Daily")
        titles.provider = "Huddle in #engineering"
        #expect(titles.resolved == "Huddle in #engineering")
        titles.human = "What I called it"
        #expect(titles.resolved == "What I called it")
    }

    @Test("an imported file keeps the name it was given")
    func anImportedFileKeepsTheNameItWasGiven() async throws {
        var titles = TitleCandidates(timestampFallback: "fallback")
        titles.filename = "Board meeting Aug 12"
        titles.ai = "Quarterly financial review"
        #expect(titles.resolved == "Board meeting Aug 12")
        #expect(titles.resolvedOrigin == "filename")
    }

    @Test("a title that sanitizes away falls back to the source")
    func aTitleThatSanitizesAwayFallsBackToTheSource() async throws {
        let name = MeetingFolderName.base(
            title: "  ...  ",
            source: .manual,
            startedAt: Self.date(year: 2026, month: 8, day: 20, hour: 15, minute: 14)
        )
        #expect(name == "Manual recording (Aug 20, 3:14 PM)")
    }

    @Test("an unnamed meeting does not write the date twice")
    func anUnnamedMeetingDoesNotWriteTheDateTwice() async throws {
        let started = Self.date(year: 2026, month: 8, day: 20, hour: 15, minute: 14)
        var metadata = MeetingMetadata(
            id: "x",
            source: .manual,
            provider: .unknown,
            createdAt: started,
            startedAt: started,
            titles: TitleCandidates(
                timestampFallback: MeetingRepository.timestampTitle(
                    startedAt: started, source: .manual
                )
            )
        )
        #expect(metadata.titles.resolvedOrigin == "timestamp")
        #expect(MeetingFolderName.base(for: metadata) == "Manual recording (Aug 20, 3:14 PM)")

        metadata.titles.ai = "Weekly retro"
        #expect(MeetingFolderName.base(for: metadata) == "Weekly retro (Aug 20, 3:14 PM)")
    }

    @Test("the log identifier drops the title")
    func theLogIdentifierDropsTheTitle() async throws {
        let started = Self.date(year: 2026, month: 8, day: 18, hour: 14, minute: 18)
        let identifier = MeetingArchiveLayout.meetingID(
            startedAt: started, source: .slackHuddle, title: "Quarterly planning"
        )
        let metadata = MeetingMetadata(
            id: identifier,
            source: .slackHuddle,
            provider: .slack,
            createdAt: started,
            startedAt: started,
            titles: TitleCandidates(
                window: "Quarterly planning", timestampFallback: "Slack huddle (Aug 18, 2:18 PM)"
            )
        )
        #expect(identifier.contains("quarterly"))
        #expect(metadata.logIdentifier == "2026-08-18-1418-slack-huddle")
        #expect(!metadata.logIdentifier.lowercased().contains("quarterly"))
        #expect(!metadata.logIdentifier.lowercased().contains("planning"))
    }

}
