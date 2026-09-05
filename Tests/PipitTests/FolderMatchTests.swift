import Foundation
import PipitCore
import Testing

/// Which folder a finished meeting is offered, and when it is offered nothing.
///
/// The silences are the point. A ladder that finds a home for every meeting is
/// a ladder that gets turned off, so the cases that must stay quiet are pinned
/// as hard as the ones that must fire.
@Suite("Folder matching")
struct FolderMatchTests {
    private static func facts(
        _ title: String,
        provider: MeetingProvider = .slack,
        series: String? = nil,
        at minute: Int = 11 * 60 + 31,
        weekday: Int = 2,
        people: [String] = ["Marlow", "Bryn Callister", "Nate"],
        excluding: [String] = []
    ) -> MeetingFacts {
        MeetingFacts(
            title: title, provider: provider, calendarSeriesID: series,
            startMinute: minute, weekday: weekday, participantNames: people,
            excludedFolders: excluding
        )
    }

    /// A standup folder: thirteen Slack huddles called the same thing, all on
    /// weekday mornings.
    private static func standup(
        filesAutomatically: Bool = true, series: String? = nil
    ) -> FolderProfile {
        let members = (0..<13).map { index in
            facts(
                "Northwind Daily", series: series,
                at: 11 * 60 + 28 + (index % 5), weekday: 2 + (index % 5)
            )
        }
        return FolderProfile(
            name: "Northwind Daily", about: "The weekday standup",
            filesAutomatically: filesAutomatically, members: members
        )
    }

    private static func client() -> FolderProfile {
        FolderProfile(
            name: "Fenwick Trust", about: "Client work with Fenwick Trust",
            members: [
                facts("Northwind <> Fenwick Trust", provider: .googleMeet, at: 14 * 60, weekday: 3,
                      people: ["Marlow", "Bryn Callister", "Rowan Ashby"]),
                facts("Rowan Ashby, Bryn Callister", provider: .googleMeet, at: 12 * 60 + 34,
                      weekday: 6, people: ["Bryn Callister", "Rowan Ashby"]),
            ]
        )
    }

    @Test("the same title on the same provider is the folder's next meeting")
    func theSameTitleOnTheSameProviderIsTheFolderSNextMeeting() async throws {
        let match = FolderMatcher.recurrence(
            of: Self.facts("Northwind Daily"), in: [Self.standup(), Self.client()]
        )
        #expect(match?.folderName == "Northwind Daily")
        #expect(match?.reason == .title)
        #expect(match?.confidence == 0.95)
        #expect(match?.reason.mayFileWithoutAsking == true)
    }

    @Test("a calendar series wins even when the title has changed")
    func aCalendarSeriesWinsEvenWhenTheTitleHasChanged() async throws {
        let folder = Self.standup(series: "series-abc")
        let match = FolderMatcher.recurrence(
            of: Self.facts("Standup", provider: .googleMeet, series: "series-abc"),
            in: [folder, Self.client()]
        )
        #expect(match?.folderName == "Northwind Daily")
        #expect(match?.reason == .calendarSeries)
        #expect(match?.confidence == 1.0)
    }

    @Test("the same slot and people carry a meeting with a different title")
    func theSameSlotAndPeopleCarryAMeetingWithADifferentTitle() async throws {
        let match = FolderMatcher.recurrence(
            of: Self.facts("Morning sync", at: 11 * 60 + 34, weekday: 3),
            in: [Self.standup(), Self.client()]
        )
        #expect(match?.folderName == "Northwind Daily")
        #expect(match?.reason == .slot)
        #expect(match?.confidence == 0.8)
    }

    @Test("the slot clause is weaker on a weekday the folder never meets")
    func theSlotClauseIsWeakerOnAWeekdayTheFolderNeverMeets() async throws {
        let match = FolderMatcher.recurrence(
            of: Self.facts("Morning sync", at: 11 * 60 + 34, weekday: 7),
            in: [Self.standup()]
        )
        #expect(match?.reason == .slot)
        #expect(match?.confidence == 0.6)
        #expect(
            !FolderMatcher.mayFileWithoutAsking(match, in: [Self.standup()]),
            "0.6 is under the filing floor"
        )
    }

    @Test("a title match far outside the folder's slot is offered, not filed")
    func aTitleMatchFarOutsideTheFolderSSlotIsOfferedNotFiled() async throws {
        let match = FolderMatcher.recurrence(
            of: Self.facts("Northwind Daily", at: 16 * 60 + 12, weekday: 7, people: ["Marlow", "Bryn Callister"]),
            in: [Self.standup()]
        )
        #expect(match?.reason == .title)
        #expect(match?.confidence == 0.7)
        #expect(!FolderMatcher.mayFileWithoutAsking(match, in: [Self.standup()]))
    }

    @Test("a folder with two members is not yet a series")
    func aFolderWithTwoMembersIsNotYetASeries() async throws {
        // Fenwick Trust holds two meetings with different titles. Nothing
        // about a third Google Meet makes it the next one.
        let match = FolderMatcher.recurrence(
            of: Self.facts("Quarterly planning", provider: .googleMeet, at: 9 * 60, weekday: 4,
                      people: ["Marlow"]),
            in: [Self.client()]
        )
        #expect(match == nil)
    }

    @Test("a folder the meeting was taken out of is never offered again")
    func aFolderTheMeetingWasTakenOutOfIsNeverOfferedAgain() async throws {
        let match = FolderMatcher.recurrence(
            of: Self.facts("Northwind Daily", excluding: ["Northwind Daily"]),
            in: [Self.standup()]
        )
        #expect(match == nil)
    }

    @Test("a model answer becomes a suggestion that may not file")
    func aModelAnswerBecomesASuggestionThatMayNotFile() async throws {
        let match = FolderMatcher.fromModel(
            [ModelFolderCandidate(
                folderName: "Fenwick Trust", confidence: 0.82,
                why: "twelve minutes on their security review",
                quote: "their security review is still open", atSeconds: 51.4
            )],
            meeting: Self.facts("Tomas Kilbride and Bryn Callister + Rowan Ashby"),
            profiles: [Self.standup(), Self.client()], reach: .clearTopics
        )
        #expect(match?.folderName == "Fenwick Trust")
        #expect(match?.reason == .model)
        #expect(match?.quote == "their security review is still open")
        #expect(match?.reason.mayFileWithoutAsking != true)
        #expect(
            !FolderMatcher.mayFileWithoutAsking(match, in: [Self.standup(), Self.client()]),
            "a model guess never files, whatever the folder switch says"
        )
    }

    @Test("two folders within a tenth of each other produce nothing")
    func twoFoldersWithinATenthOfEachOtherProduceNothing() async throws {
        let match = FolderMatcher.fromModel(
            [
                ModelFolderCandidate(
                    folderName: "Fenwick Trust", confidence: 0.84, why: "Bryn is in it",
                    quote: "Bryn said", atSeconds: 4
                ),
                ModelFolderCandidate(
                    folderName: "Northwind Daily", confidence: 0.79, why: "Bryn is in it too",
                    quote: "Bryn said", atSeconds: 4
                ),
            ],
            meeting: Self.facts("Bryn Callister"),
            profiles: [Self.standup(), Self.client()], reach: .clearTopics
        )
        #expect(match == nil)
    }

    @Test("an answer under the reach floor is not shown")
    func anAnswerUnderTheReachFloorIsNotShown() async throws {
        let candidate = ModelFolderCandidate(
            folderName: "Fenwick Trust", confidence: 0.62, why: "they came up once",
            quote: "Fenwick Trust", atSeconds: 12
        )
        #expect(FolderMatcher.fromModel(
            [candidate], meeting: Self.facts("Bryn Callister"),
            profiles: [Self.client()], reach: .clearTopics
        ) == nil)
        #expect(FolderMatcher.fromModel(
                [candidate], meeting: Self.facts("Bryn Callister"),
                profiles: [Self.client()], reach: .anyLikely
            )?.folderName == "Fenwick Trust")
    }

    @Test("an answer with no quote behind it is dropped")
    func anAnswerWithNoQuoteBehindItIsDropped() async throws {
        #expect(FolderMatcher.fromModel(
            [ModelFolderCandidate(
                folderName: "Fenwick Trust", confidence: 0.9, why: "it felt like them"
            )],
            meeting: Self.facts("Bryn Callister"),
            profiles: [Self.client()], reach: .clearTopics
        ) == nil)
    }

    @Test("no model answer is taken when the reach is recurring meetings only")
    func noModelAnswerIsTakenWhenTheReachIsRecurringMeetingsOnly() async throws {
        #expect(FolderMatcher.fromModel(
            [ModelFolderCandidate(
                folderName: "Fenwick Trust", confidence: 0.99, why: "named throughout",
                quote: "Fenwick Trust", atSeconds: 3
            )],
            meeting: Self.facts("Bryn Callister"),
            profiles: [Self.client()], reach: .recurringOnly
        ) == nil)
    }

    @Test("a folder the model invented is not offered")
    func aFolderTheModelInventedIsNotOffered() async throws {
        #expect(FolderMatcher.fromModel(
            [ModelFolderCandidate(
                folderName: "Fico", confidence: 0.95, why: "a new client",
                quote: "Fico", atSeconds: 8
            )],
            meeting: Self.facts("First Fico Meeting"),
            profiles: [Self.standup(), Self.client()], reach: .clearTopics
        ) == nil)
    }

}
