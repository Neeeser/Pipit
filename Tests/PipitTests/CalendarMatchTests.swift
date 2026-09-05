import Foundation
import PipitCore
import Testing

/// Which calendar entry may name a meeting.
@Suite("CalendarMatch")
struct CalendarMatchTests {
    private static let start = Date(timeIntervalSince1970: 1_787_000_000)

    private static func candidate(
        _ title: String, offsetMinutes: Double, durationMinutes: Double,
        isAllDay: Bool = false, haystack: String = ""
    ) -> CalendarCandidate {
        let began = start.addingTimeInterval(offsetMinutes * 60)
        return CalendarCandidate(
            identifier: title, title: title, startDate: began,
            endDate: began.addingTimeInterval(durationMinutes * 60),
            isAllDay: isAllDay, haystack: haystack
        )
    }

    @Test("a shift that contains the recording does not name it")
    func aShiftThatContainsTheRecordingDoesNotNameIt() async throws {
        // Measured: a 38-second recording was titled "5-10" and two
        // others "12-5", after the shifts they happened during. A
        // containing event covered the whole recording, which scored the
        // maximum overlap available, so the longest entry of the day won
        // every time.
        let shift = Self.candidate("12-5", offsetMinutes: -120, durationMinutes: 300)
        let match = CalendarMatchPolicy.best(
            among: [shift], startedAt: Self.start,
            endedAt: Self.start.addingTimeInterval(38),
            meetingURL: nil, providerMeetingID: nil
        )
        #expect(match == nil, "got \(match?.candidate.title ?? "nil")")
    }

    @Test("an all-day entry does not name a meeting")
    func anAllDayEntryDoesNotNameAMeeting() async throws {
        let holiday = Self.candidate(
            "Out of office", offsetMinutes: -600, durationMinutes: 1_440, isAllDay: true
        )
        #expect(
            CalendarMatchPolicy.best(
                among: [holiday], startedAt: Self.start,
                endedAt: Self.start.addingTimeInterval(1_800),
                meetingURL: nil, providerMeetingID: nil
            ) == nil
        )
    }

    @Test("the real meeting still wins against the block it sits inside")
    func theRealMeetingStillWinsAgainstTheBlockItSitsInside() async throws {
        let shift = Self.candidate("12-5", offsetMinutes: -120, durationMinutes: 300)
        let standup = Self.candidate("Platform standup", offsetMinutes: 0, durationMinutes: 30)
        let match = try #require(CalendarMatchPolicy.best(
            among: [shift, standup], startedAt: Self.start,
            endedAt: Self.start.addingTimeInterval(1_500),
            meetingURL: nil, providerMeetingID: nil
        ))
        #expect(match.candidate.title == "Platform standup")
    }

    @Test("recording the tail of a meeting still matches it")
    func recordingTheTailOfAMeetingStillMatchesIt() async throws {
        // Joining late is ordinary, and the recording then covers a
        // fraction of the event. Timing is still what identifies it.
        let review = Self.candidate("Design review", offsetMinutes: -25, durationMinutes: 30)
        let match = try #require(CalendarMatchPolicy.best(
            among: [review], startedAt: Self.start,
            endedAt: Self.start.addingTimeInterval(300),
            meetingURL: nil, providerMeetingID: nil
        ))
        #expect(match.candidate.title == "Design review")
    }

    @Test("an invitation naming this meeting names it whatever its length")
    func anInvitationNamingThisMeetingNamesItWhateverItsLength() async throws {
        // A day-long workshop with the Meet link in the invitation is
        // the meeting, and the link says so where timing cannot.
        let workshop = Self.candidate(
            "Onboarding workshop", offsetMinutes: -60, durationMinutes: 480,
            haystack: "https://meet.google.com/abc-defg-hij"
        )
        let match = try #require(CalendarMatchPolicy.best(
            among: [workshop], startedAt: Self.start,
            endedAt: Self.start.addingTimeInterval(1_800),
            meetingURL: nil, providerMeetingID: "abc-defg-hij"
        ))
        #expect(match.candidate.title == "Onboarding workshop")
        #expect(match.score >= 0.7, "the invitation is decisive on its own")
    }
}
