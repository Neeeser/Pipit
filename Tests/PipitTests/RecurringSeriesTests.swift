import Foundation
import PipitCore
import Testing

/// The offer made after a meeting is filed by hand: what looks like this one,
/// and what rule would catch the rest.
@Suite("Recurring series")
struct RecurringSeriesTests {
    private static func facts(
        _ title: String, provider: MeetingProvider = .slack, at minute: Int = 11 * 60 + 30,
        weekday: Int = 2, people: [String] = ["Marlow", "Bryn Callister", "Nate"],
        series: String? = nil
    ) -> MeetingFacts {
        MeetingFacts(
            title: title, provider: provider, calendarSeriesID: series,
            startMinute: minute, weekday: weekday, participantNames: people
        )
    }

    private static var standups: [MeetingFacts] {
        (0..<13).map { index in
            facts("Northwind Daily", at: 11 * 60 + 28 + (index % 5), weekday: 2 + (index % 5))
        }
    }

    @Test("thirteen meetings with one title propose a title and provider rule")
    func thirteenMeetingsWithOneTitleProposeATitleAndProviderRule() async throws {
        let archive = Self.standups + [Self.facts("Tudor Meeting 2", at: 13 * 60 + 30)]
        guard let proposal = RecurringSeries.propose(
            for: Self.facts("Northwind Daily"), among: archive
        ) else {
            Issue.record("nothing proposed")
            return
        }

        #expect(proposal.defaultTicks == [.title, .provider])
        #expect(proposal.lookalikeCount == 13, "the other meeting is not caught")
        let rule = proposal.rule(ticking: proposal.defaultTicks, from: Self.facts("Northwind Daily"))
        #expect(rule.titleIs == "Northwind Daily")
        #expect(rule.provider == .slack)
        #expect(rule.weekdays.isEmpty, "the slot is offered, not assumed")
    }

    @Test("the slot clause covers every time they actually started")
    func theSlotClauseCoversEveryTimeTheyActuallyStarted() async throws {
        guard let proposal = RecurringSeries.propose(
            for: Self.facts("Northwind Daily"), among: Self.standups
        ) else {
            Issue.record("nothing proposed")
            return
        }
        // 11:28 through 11:32, padded by a quarter of an hour either way.
        #expect(proposal.window.after == 11 * 60 + 13)
        #expect(proposal.window.before == 11 * 60 + 47)
        #expect(proposal.weekdays == [2, 3, 4, 5, 6])
        let slot = proposal.rule(
            ticking: [.title, .provider, .slot], from: Self.facts("Northwind Daily")
        )
        #expect(slot.matches(Self.facts("Northwind Daily", at: 11 * 60 + 45, weekday: 6)))
        #expect(
            !slot.matches(Self.facts("Northwind Daily", at: 16 * 60, weekday: 7)),
            "a Saturday afternoon is not the standup"
        )
    }

    @Test("a calendar series is offered on its own")
    func aCalendarSeriesIsOfferedOnItsOwn() async throws {
        let archive = Self.standups.map { fact -> MeetingFacts in
            var copy = fact
            copy.calendarSeriesID = "series-abc"
            return copy
        }
        guard let proposal = RecurringSeries.propose(
            for: Self.facts("Standup", provider: .googleMeet, series: "series-abc"),
            among: archive
        ) else {
            Issue.record("nothing proposed")
            return
        }
        #expect(proposal.defaultTicks == [.calendarSeries])
        let rule = proposal.rule(
            ticking: proposal.defaultTicks,
            from: Self.facts("Standup", provider: .googleMeet, series: "series-abc")
        )
        #expect(rule.calendarSeriesIDs == ["series-abc"])
        #expect(rule.titleIs == nil, "the title changed once already")
    }

    @Test("two meetings that look alike are not a series")
    func twoMeetingsThatLookAlikeAreNotASeries() async throws {
        let archive = [Self.facts("Kickoff", at: 9 * 60), Self.facts("Kickoff", at: 9 * 60)]
        #expect(RecurringSeries.propose(for: Self.facts("Kickoff", at: 9 * 60), among: archive) == nil)
    }

    @Test("people who are always there are offered, one-offs are not")
    func peopleWhoAreAlwaysThereAreOfferedOneOffsAreNot() async throws {
        let archive = Self.standups.enumerated().map { index, fact -> MeetingFacts in
            var copy = fact
            if index == 0 { copy.participantNames.append("Visitor") }
            return copy
        }
        guard let proposal = RecurringSeries.propose(
            for: Self.facts("Northwind Daily"), among: archive
        ) else {
            Issue.record("nothing proposed")
            return
        }
        #expect(!proposal.participants.contains("Visitor"))
        #expect(proposal.participants.count == 2)
        let clause = proposal.clauses.first { $0.kind == .participants }
        #expect(clause?.isOnByDefault != true, "people are never ticked for you")
    }

    @Test("an empty rule admits nothing at all")
    func anEmptyRuleAdmitsNothingAtAll() async throws {
        #expect(!FolderRule().matches(Self.facts("Anything")))
    }

}
