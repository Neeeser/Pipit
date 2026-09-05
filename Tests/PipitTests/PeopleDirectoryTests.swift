import AppKit
import Foundation
import PipitCore
import PipitServices
import PipitSpeakers
import PipitUI
import SQLite3
import Testing

// What a person keeps about somebody, and how a few hundred of them are put on
// screen.
//
// Notes and badges are the first fields on an identity that exist only for a
// reader, so the rules that already cover names have to be shown to cover
// these too: a delete takes them, a merge leaves them where an unmerge finds
// them again, and the picture goes with the row.

// MARK: helpers

private func makeStore() throws -> (SpeakerStore, URL) {
    try SpeakerFixtures.makeStore()
}

private func entry(
    _ id: Int64,
    name: String? = nil,
    organization: String? = nil,
    notes: String? = nil,
    aliases: [String] = [],
    anonymousNumber: Int? = nil,
    profile: VoiceProfileStatus = .none,
    meetings: Int = 0,
    isLocalUser: Bool = false,
    lastSeen: Date? = nil
) -> SpeakerDirectoryEntry {
    SpeakerDirectoryEntry(
        identity: Identity(
            id: IdentityID(id),
            kind: name == nil ? .anonymous : .person,
            displayName: name,
            anonymousNumber: anonymousNumber,
            aliases: aliases,
            organization: organization,
            notes: notes,
            isLocalUser: isLocalUser,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: lastSeen
        ),
        profile: profile,
        meetingCount: meetings
    )
}

/// How the directory is ordered for the question "who is this voice?".
///
/// Alphabetical order answers a different question, and at forty voices it
/// scattered the three people actually in the room through the list.
@Suite("PeoplePicker")
struct PeoplePickerTests {
    @Test("the people in this meeting come first, then recent, then the rest")
    func thePeopleInThisMeetingComeFirstThenRecentThenTheRest() async throws {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            entry(1, name: "Zoe", organization: "Acme"),
            entry(2, name: "Brian M", organization: "Acme"),
            entry(3, name: "Ali Rodell", lastSeen: day),
            entry(4, name: "Alastair"),
        ]
        let sections = PeoplePickerRanking.sections(
            entries, context: [IdentityID(2): .onAChip]
        )
        #expect(
            sections.map(\.title) == [
                PeoplePickerRanking.inThisMeetingTitle, PeoplePickerRanking.recentTitle,
                PeoplePickerRanking.everyoneTitle,
            ]
        )
        #expect(sections[0].rows.map(\.entry.identity.resolvedName) == ["Brian M"])
        #expect(sections[1].rows.map(\.entry.identity.resolvedName) == ["Ali Rodell"])
        #expect(
            sections[2].rows.map(\.entry.identity.resolvedName) == ["Alastair", "Zoe"],
            "what is left is alphabetical"
        )
    }

    @Test("nobody appears twice")
    func nobodyAppearsTwice() async throws {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            entry(1, name: "Brian M", lastSeen: day),
            entry(2, name: "Ali Rodell", lastSeen: day.addingTimeInterval(-60)),
        ]
        let sections = PeoplePickerRanking.sections(
            entries, context: [IdentityID(1): .onAChip]
        )
        let names = sections.flatMap(\.rows).map(\.entry.identity.resolvedName)
        #expect(names.count == Set(names).count, "a person offered twice is two answers")
        #expect(sections[0].rows.map(\.entry.identity.resolvedName) == ["Brian M"])
        #expect(sections[1].rows.map(\.entry.identity.resolvedName) == ["Ali Rodell"])
    }

    @Test("someone already heard is offered above someone merely expected")
    func someoneAlreadyHeardIsOfferedAboveSomeoneMerelyExpected() async throws {
        let sections = PeoplePickerRanking.sections(
            [entry(1, name: "Ali Rodell"), entry(2, name: "Brian M")],
            context: [IdentityID(1): .expected, IdentityID(2): .onAChip]
        )
        #expect(
            sections.first?.rows.map(\.entry.identity.resolvedName) == ["Brian M", "Ali Rodell"],
            "a voice already heard is a likelier answer than a name off the invite"
        )
    }

    @Test("only the five most recent are offered before the full list")
    func onlyTheFiveMostRecentAreOfferedBeforeTheFullList() async throws {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = (1...7).map { index in
            entry(
                Int64(index), name: "Person \(index)",
                lastSeen: day.addingTimeInterval(Double(index) * 60)
            )
        }
        let sections = PeoplePickerRanking.sections(entries)
        #expect(
            sections[0].rows.map(\.entry.identity.resolvedName)
                == ["Person 7", "Person 6", "Person 5", "Person 4", "Person 3"],
            "most recent first, and only five of them"
        )
        #expect(sections[1].rows.count == 2, "the rest are still reachable")
    }

    @Test("searching collapses recent into one list and keeps the meeting's own")
    func searchingCollapsesRecentIntoOneListAndKeepsTheMeetingsOwn() async throws {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            entry(1, name: "Chris B", organization: "Acme"),
            entry(2, name: "Chris Latimer", lastSeen: day),
            entry(3, name: "Christine Ayers"),
            entry(4, name: "Dana Kwon", lastSeen: day),
        ]
        let sections = PeoplePickerRanking.sections(
            entries, context: [IdentityID(1): .onAChip], query: "chris"
        )
        #expect(
            sections.map(\.title)
                == [PeoplePickerRanking.inThisMeetingTitle, PeoplePickerRanking.everyoneTitle],
            "splitting five recent names off three results hides the split's reason"
        )
        #expect(sections[0].rows.map(\.entry.identity.resolvedName) == ["Chris B"])
        #expect(
            sections[1].rows.map(\.entry.identity.resolvedName)
                == ["Chris Latimer", "Christine Ayers"],
            "Dana does not match, and the section is alphabetical"
        )
    }

    @Test("a search matching nobody leaves no sections at all")
    func aSearchMatchingNobodyLeavesNoSectionsAtAll() async throws {
        #expect(
            PeoplePickerRanking.sections(
                [entry(1, name: "Chris B")],
                context: [IdentityID(1): .onAChip], query: "dara"
            ).isEmpty,
            "the empty result is what offers to create the person typed"
        )
    }

    @Test("the list follows the highlight only when the keyboard moves it")
    func theListFollowsTheHighlightOnlyWhenTheKeyboardMovesIt() async throws {
        await aHoveredRowDoesNotScrollTheList()
    }

    @Test("the line under a name says the organization and why they are offered")
    func theLineUnderANameSaysTheOrganizationAndWhyTheyAreOffered() async throws {
        #expect(
            PeoplePickerRanking.detail(
                of: entry(1, name: "Brian M", organization: "Acme"), context: .onAChip
            ) == "Acme · already on a chip here"
        )
        #expect(
            PeoplePickerRanking.detail(of: entry(2, name: "Hal"), context: .expected)
                == "Expected here, not heard yet",
            "with no organization the reason leads, and reads as a sentence"
        )
        #expect(
            PeoplePickerRanking.detail(of: entry(3, name: "Hal", meetings: 1))
                == "Heard in 1 meeting"
        )
        #expect(
            PeoplePickerRanking.detail(of: entry(4, name: "Hal", meetings: 6))
                == "Heard in 6 meetings"
        )
        #expect(
            PeoplePickerRanking.detail(of: entry(5, name: "Hal")) == "",
            "somebody with nothing to say about them gets no second line"
        )
    }
}

@Suite("PersonDetail")
struct PersonDetailTests {
    @Test("notes, badges and a picture round trip")
    func notesBadgesAndAPictureRoundTrip() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let chris = try await store.createPerson(name: "Chris", organization: "Acme")

        try await store.setNotes("Owns the ingest retries.", on: chris.id)
        try await store.setBadges([.slack, .zoom], on: chris.id)
        try await store.setAvatar(Data([0x89, 0x50, 0x4E, 0x47]), on: chris.id)

        let current = try await store.current(chris.id)
        let read = try #require(current)
        #expect(read.notes == "Owns the ingest retries.")
        #expect(read.badges == [.slack, .zoom])
        #expect(read.hasAvatar, "the list needs to know a picture exists")
        let avatar = try await store.avatar(of: chris.id)
        #expect(avatar == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test("blank notes clear the field rather than storing whitespace")
    func blankNotesClearTheFieldRatherThanStoringWhitespace() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let chris = try await store.createPerson(name: "Chris")
        try await store.setNotes("something", on: chris.id)
        try await store.setNotes("   \n ", on: chris.id)
        // A participant block built from whitespace prints a name with
        // an empty line under it in every transcript they are in.
        let notes = try await store.current(chris.id)?.notes
        #expect(notes == nil)
    }

    @Test("replacing the badge set removes what is no longer there")
    func replacingTheBadgeSetRemovesWhatIsNoLongerThere() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let chris = try await store.createPerson(name: "Chris")
        try await store.setBadges([.slack, .zoom, .phone], on: chris.id)
        try await store.setBadges([.zoom], on: chris.id)
        let badges = try await store.current(chris.id)?.badges
        #expect(badges == [.zoom])
    }

    @Test("deleting a person takes their notes, badges and picture")
    func deletingAPersonTakesTheirNotesBadgesAndPicture() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let chris = try await store.createPerson(name: "Chris")
        try await store.setNotes("Owns the ingest retries.", on: chris.id)
        try await store.setBadges([.slack], on: chris.id)
        try await store.setAvatar(Data([0x89, 0x50]), on: chris.id)

        try await store.delete(chris.id)

        let current = try await store.current(chris.id)
        #expect(current == nil)
        let avatar = try await store.avatar(of: chris.id)
        #expect(
            avatar == nil,
            "the cascade has to reach the picture, or a deleted person leaves their face behind"
        )
    }

    @Test("a merged person keeps their own notes for an unmerge to find")
    func aMergedPersonKeepsTheirOwnNotesForAnUnmergeToFind() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let chris = try await store.createPerson(name: "Chris")
        let duplicate = try await store.createPerson(name: "C. Fowler")
        try await store.setNotes("The other row's notes.", on: duplicate.id)
        try await store.setNotes("Owns the ingest retries.", on: chris.id)

        try await store.merge(duplicate.id, into: chris.id)
        // Reads resolve through the tombstone, so the duplicate reads as
        // Chris and shows his notes.
        let merged = try await store.current(duplicate.id)?.notes
        #expect(merged == "Owns the ingest retries.")

        try await store.unmerge(duplicate.id)
        let unmerged = try await store.current(duplicate.id)?.notes
        #expect(
            unmerged == "The other row's notes.",
            "a merge moves nothing, so separating it has to find the notes still there"
        )
    }

    @Test("one organization is set across a whole selection")
    func oneOrganizationIsSetAcrossAWholeSelection() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let people = try await [
            store.createPerson(name: "Chris"),
            store.createPerson(name: "Dana"),
            store.createPerson(name: "Priya"),
        ]
        try await store.setOrganization("Acme", on: [people[0].id, people[2].id])
        let first = try await store.current(people[0].id)?.organization
        #expect(first == "Acme")
        let second = try await store.current(people[1].id)?.organization
        #expect(second == nil)
        let third = try await store.current(people[2].id)?.organization
        #expect(third == "Acme")
    }

    @Test("a version 1 database gains the new fields and keeps its people")
    func aVersionOneDatabaseGainsTheNewFieldsAndKeepsItsPeople() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("voices.sqlite")
        try writeVersionOneDatabase(at: url, name: "Chris")

        let store = try SpeakerStore(url: url)
        let people = try await store.identities(kind: .person)
        #expect(people.count == 1, "the migration must not drop anybody")
        #expect(people.first?.resolvedName == "Chris")
        #expect(people.first?.notes == nil)
        #expect(people.first?.badges == [])

        // And the columns the migration added are writable, which is
        // what it was for.
        let chris = try #require(people.first)
        try await store.setNotes("Still here.", on: chris.id)
        try await store.setBadges([.slack], on: chris.id)
        let notes = try await store.current(chris.id)?.notes
        #expect(notes == "Still here.")
        let badges = try await store.current(chris.id)?.badges
        #expect(badges == [.slack])
    }
}

@Suite("PeopleDirectoryFilter")
struct PeopleDirectoryFilterTests {
    @Test("you are the first section, whatever your organization is")
    func youAreTheFirstSectionWhateverYourOrganizationIs() async throws {
        // The row wanted most often and hardest to find: filed under an
        // organization it sits among colleagues, in alphabetical order,
        // named like anybody else.
        let entries = [
            entry(1, name: "Andrew", organization: "Acme", isLocalUser: true),
            entry(2, name: "Aaron", organization: "Acme"),
            entry(3, name: "Priya"),
            entry(4, anonymousNumber: 2),
        ]
        let sections = PeopleDirectoryFilter.sections(entries)
        #expect(sections.first?.title == PeopleDirectoryFilter.youTitle)
        #expect(sections.first?.entries.map(\.identity.resolvedName) == ["Andrew"])
        #expect(
            !sections.dropFirst().contains { $0.entries.contains { $0.identity.isLocalUser } },
            "one row, in one place"
        )
        #expect(
            sections.dropFirst().first?.entries.map(\.identity.resolvedName) == ["Aaron"],
            "the organization keeps everybody else"
        )
    }

    @Test("a search that does not match you leaves the section out")
    func aSearchThatDoesNotMatchYouLeavesTheSectionOut() async throws {
        let entries = [
            entry(1, name: "Andrew", isLocalUser: true),
            entry(2, name: "Priya"),
        ]
        #expect(
            PeopleDirectoryFilter.sections(entries, query: "priya").map(\.title)
                == [PeopleDirectoryFilter.noOrganizationTitle]
        )
    }

    @Test("search reaches the organization, the aliases and the notes")
    func searchReachesTheOrganizationTheAliasesAndTheNotes() async throws {
        let entries = [
            entry(1, name: "Chris Fowler", organization: "Acme"),
            entry(2, name: "Dana Kwon", aliases: ["DK"]),
            entry(3, name: "Priya Raman", notes: "Owns the ingest retries."),
        ]
        func names(_ query: String) -> [String] {
            PeopleDirectoryFilter.sections(entries, query: query)
                .flatMap(\.entries).map(\.identity.resolvedName)
        }
        #expect(names("acme") == ["Chris Fowler"])
        #expect(names("dk") == ["Dana Kwon"], "an alias is how a name was written elsewhere")
        #expect(
            names("ingest") == ["Priya Raman"],
            "notes are the field people fill in to tell two similar voices apart"
        )
        #expect(names("nobody") == [])
    }

    @Test("unnamed voices sit below the people, in numeric order")
    func unnamedVoicesSitBelowThePeopleInNumericOrder() async throws {
        let entries = [
            entry(10, anonymousNumber: 10),
            entry(9, anonymousNumber: 9),
            entry(1, name: "Chris Fowler", organization: "Acme"),
        ]
        let sections = PeopleDirectoryFilter.sections(entries)
        #expect(sections.map(\.title) == ["Acme", PeopleDirectoryFilter.unnamedTitle])
        #expect(
            sections.last?.entries.map(\.identity.anonymousNumber) == [9, 10],
            "#9 sorts before #10, which sorting the text would not do"
        )
    }

    @Test("people with no organization group above the unnamed voices")
    func peopleWithNoOrganizationGroupAboveTheUnnamedVoices() async throws {
        let entries = [
            entry(1, name: "Chris Fowler", organization: "Acme"),
            entry(2, name: "Dana Kwon"),
            entry(3, anonymousNumber: 3),
        ]
        #expect(
            PeopleDirectoryFilter.sections(entries).map(\.title)
                == ["Acme", PeopleDirectoryFilter.noOrganizationTitle,
                    PeopleDirectoryFilter.unnamedTitle]
        )
    }

    @Test("a right-click acts on the row under the pointer, not the selection")
    func aRightClickActsOnTheRowUnderThePointerNotTheSelection() async throws {
        try await aRightClickActsOnTheRowUnderIt()
    }

    @Test("deleting a meeting stops it counting towards a voice's meetings")
    func deletingAMeetingStopsItCountingTowardsAVoicesMeetings() async throws {
        // The occurrence rows outlive the folder, and the People window
        // counts meetings from them. Left behind, a deleted recording
        // kept counting towards "heard in 3 meetings" forever.
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let chris = try await store.createPerson(name: "Chris")
        for meeting in ["m-1", "m-2"] {
            try await store.recordOccurrence(
                meetingID: meeting, clusterID: "remote-001_speaker_00", track: .remote,
                speechSeconds: 120, embedding: nil, model: nil, resolution: nil,
                identityID: chris.id, source: .human,
                humanVerified: true, wasExpectedParticipant: false
            )
        }
        let before = try await store.meetingCount(for: chris.id)
        #expect(before == 2)

        let deleted = try await store.deleteOccurrences(meetingID: "m-1")
        #expect(deleted == 1)

        let after = try await store.meetingCount(for: chris.id)
        #expect(after == 1)
        let remaining = try await store.meetingsReferencing(chris.id)
        #expect(
            remaining == ["m-2"],
            "and the meeting still on disk is the one that is left"
        )
    }

    @Test("each filter admits what it says it does")
    func eachFilterAdmitsWhatItSaysItDoes() async throws {
        let entries = [
            entry(1, name: "Chris Fowler", profile: .ready(samples: 4, recordings: 4, speechSeconds: 600)),
            entry(2, name: "Dana Kwon"),
            entry(3, anonymousNumber: 3, profile: .learning(samples: 1, recordings: 1, speechSeconds: 60)),
        ]
        func count(_ filter: PeopleFilter) -> Int {
            PeopleDirectoryFilter.sections(entries, filter: filter).flatMap(\.entries).count
        }
        #expect(count(.all) == 3)
        #expect(count(.named) == 2)
        #expect(count(.unnamed) == 1)
        #expect(count(.withVoiceProfile) == 2)
    }
}

@Suite("TranscriptParticipants")
struct TranscriptParticipantsTests {
    @Test("the participant block carries organization and notes above the dialogue")
    func theParticipantBlockCarriesOrganizationAndNotesAboveTheDialogue() async throws {
        let transcript = CanonicalTranscript(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            utterances: [PeopleFixtures.utterance("s1", "We ship Friday.", at: 0)]
        )
        var speakers = SpeakerMap()
        speakers.assign("Priya Raman", to: "s1")
        let markdown = TranscriptRenderer().markdown(
            transcript: transcript,
            speakers: speakers,
            title: "Roadmap sync",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600,
            participants: [
                TranscriptParticipant(
                    name: "Priya Raman", organization: "Acme",
                    notes: "Owns the ingest retries."
                )
            ]
        )
        let participantsAt = try #require(markdown.range(of: "## Participants"))
        let dialogueAt = try #require(markdown.range(of: "We ship Friday."))
        #expect(
            participantsAt.lowerBound < dialogueAt.lowerBound,
            "a reader who meets the notes after the conversation has already decided who everybody is"
        )
        #expect(markdown.contains("**Priya Raman** · Acme"))
        #expect(markdown.contains("Owns the ingest retries."))
    }

    @Test("nobody with notes means no participant section at all")
    func nobodyWithNotesMeansNoParticipantSectionAtAll() async throws {
        let transcript = CanonicalTranscript(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            utterances: [PeopleFixtures.utterance("s1", "We ship Friday.", at: 0)]
        )
        var speakers = SpeakerMap()
        speakers.assign("Priya Raman", to: "s1")
        let markdown = TranscriptRenderer().markdown(
            transcript: transcript,
            speakers: speakers,
            title: "Roadmap sync",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600,
            participants: [TranscriptParticipant(name: "Priya Raman")]
        )
        #expect(
            !markdown.contains("## Participants"),
            "a name with nothing attached adds nothing the dialogue does not already say"
        )
    }
}

/// The participant block is derived, so the question is never whether the
/// database is right: it is whether the markdown on disk was rewritten when
/// the database changed.
@Suite("ParticipantBlockRefresh")
struct ParticipantBlockRefreshTests {
    @Test("rebuilding a transcript keeps the participant block")
    func rebuildingATranscriptKeepsTheParticipantBlock() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, storeRoot) = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeRoot) }

        let (pipeline, meeting, _) = try await makeRenderedMeeting(
            root: root, store: store, notes: "Owns the ingest retries."
        )
        #expect(try markdown(meeting).contains("Owns the ingest retries."))

        // Rebuild re-assembles and re-renders. Rendering without the
        // participants erased a block nothing would put back until
        // somebody happened to edit this person again.
        try await pipeline.rebuildTranscript(
            meetingID: try meeting.readMetadata().id
        )

        #expect(
            try markdown(meeting).contains("Owns the ingest retries."),
            "a derived file rebuilt from source has to be rebuilt whole"
        )
    }

    @Test("deleting a person clears their notes from transcripts already rendered")
    func deletingAPersonClearsTheirNotesFromTranscriptsAlreadyRendered() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, storeRoot) = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeRoot) }

        let (pipeline, meeting, chris) = try await makeRenderedMeeting(
            root: root, store: store, notes: "Owns the ingest retries."
        )
        #expect(try markdown(meeting).contains("Owns the ingest retries."))

        // What the runtime does: the meetings are collected while the row
        // still exists, because afterwards nothing can find them.
        let affected = try await store.meetingsReferencing(chris.id)
        try await store.delete(chris.id)
        await pipeline.rerenderMeetings(affected)

        #expect(
            !(try markdown(meeting).contains("Owns the ingest retries.")),
            "the confirmation says the notes are removed, so they cannot stay in the export"
        )
    }
}

private func markdown(_ store: MeetingStore) throws -> String {
    try String(contentsOf: store.layout.transcriptMarkdown, encoding: .utf8)
}

/// A meeting on disk whose transcript.md has been rendered once, with one
/// named person linked to its only speaker.
private func makeRenderedMeeting(
    root: URL, store: SpeakerStore, notes: String
) async throws -> (ProcessingPipeline, MeetingStore, Identity) {
    let meeting = try PipelineFixtures.makeRecordedMeeting(root: root)
    // Raw words and diarization on disk, so a rebuild has something to
    // re-assemble from and the test is not passing on an early return.
    var raw = try meeting.store.readRawTranscript()
    raw.chunks.append(RawTranscriptChunk(
        id: "remote_chunk_001", track: .remote, timelineOffset: 0,
        durationSeconds: 6, model: "stub", responseFormat: "local_text",
        segments: [RawTranscriptSegment(
            start: 0, end: 2, text: "we ship friday", speaker: nil,
            words: [
                RawTranscriptWord(start: 0.0, end: 0.4, text: " we"),
                RawTranscriptWord(start: 0.5, end: 0.8, text: " ship"),
                RawTranscriptWord(start: 0.9, end: 1.2, text: " friday"),
            ]
        )],
        purpose: .words
    ))
    try meeting.store.writeRawTranscript(raw)
    var diarization = try meeting.store.readRawDiarization()
    diarization.setActive(DiarizationRun(
        id: "run-remote", track: .remote, backend: "stub",
        producedAt: Date(timeIntervalSince1970: 0), timelineOffset: 0,
        intervals: [DiarizationInterval(start: 0, end: 2, clusterID: "A")]
    ))
    try meeting.store.writeRawDiarization(diarization)

    let chris = try await store.createPerson(name: "Chris")
    try await store.setNotes(notes, on: chris.id)
    try await store.recordOccurrence(
        meetingID: meeting.metadata.id, clusterID: "remote-001_speaker_00", track: .remote,
        speechSeconds: 120, embedding: nil, model: nil, resolution: nil,
        identityID: chris.id, source: .human,
        humanVerified: true, wasExpectedParticipant: false
    )

    try meeting.store.writeCanonicalTranscript(CanonicalTranscript(
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        utterances: [PeopleFixtures.utterance("remote-001_speaker_00", "We ship Friday.", at: 0)]
    ))
    var map = SpeakerMap()
    map.assign("Chris", to: "remote-001_speaker_00", identityID: chris.id)
    try meeting.store.writeSpeakerMap(map)

    let pipeline = ProcessingPipeline(
        repository: meeting.repository,
        backend: FakeAIBackend(),
        backends: ProcessingBackends(
            transcription: { _, _ in fatalError("not reached") },
            diarization: { _, _ in fatalError("not reached") },
            speakers: SpeakerRecognitionService(store: store)
        ),
        clock: ManualClock(),
        settingsProvider: { AppSettings() },
        wait: { _ in }
    )
    // The first render, so the assertions are about a rewrite rather than
    // about a file appearing.
    try await pipeline.refreshCachedNames(for: chris.id)
    return (pipeline, meeting.store, chris)
}

/// The meetings on a person's profile, and the audio behind them.
@Suite("PersonMeetings")
struct PersonMeetingsTests {
    @Test("a person's profile lists the meetings they were heard in")
    func aPersonsProfileListsTheMeetingsTheyWereHeardIn() async throws {
        try await appearancesListEveryMeeting()
    }

    @Test("a sample plays this person's longest turn")
    func aSamplePlaysThisPersonsLongestTurn() async throws {
        try await theSampleIsTheLongestTurn()
    }

    @Test("a person with no audio on disk offers nothing to play")
    func aPersonWithNoAudioOnDiskOffersNothingToPlay() async throws {
        try await noAudioMeansNoSample()
    }
}

@MainActor
private func appearancesListEveryMeeting() async throws {
    let root = try TestPaths.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = RuntimeFixtures.makeRuntime(root: root)
    let store = try #require(runtime.speakerStore)
    let ben = try await store.createPerson(name: "Ben")

    let older = try await PeopleFixtures.makeAppearance(
        store: store, identityID: ben.id, root: root,
        title: "Design review", at: Date(timeIntervalSince1970: 1_787_000_000),
        turns: [(0, 12)]
    )
    let newer = try await PeopleFixtures.makeAppearance(
        store: store, identityID: ben.id, root: root,
        title: "Weekly sync", at: Date(timeIntervalSince1970: 1_787_900_000),
        turns: [(0, 4), (10, 15)]
    )

    let appearances = await runtime.appearances(of: ben.id)
    #expect(appearances.map(\.meetingID) == [newer, older], "newest first")
    #expect(appearances.first?.title == "Weekly sync")
    #expect(appearances.first?.speechSeconds == 9)
    let everyOneHasAudio = appearances.allSatisfy(\.hasAudio)
    #expect(everyOneHasAudio)

    // Nobody else's meetings, and nobody else's silence.
    let stranger = try await store.createPerson(name: "Priya")
    let strangers = await runtime.appearances(of: stranger.id)
    #expect(strangers.isEmpty, "a person heard in nothing has nothing to list")
}

@MainActor
private func theSampleIsTheLongestTurn() async throws {
    let root = try TestPaths.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = RuntimeFixtures.makeRuntime(root: root)
    let store = try #require(runtime.speakerStore)
    let ben = try await store.createPerson(name: "Ben")
    let meetingID = try await PeopleFixtures.makeAppearance(
        store: store, identityID: ben.id, root: root,
        title: "Weekly sync", at: Date(timeIntervalSince1970: 1_787_900_000),
        turns: [(0, 3), (30, 60)]
    )

    let found = await runtime.voiceSample(of: ben.id, inMeeting: meetingID)
    let sample = try #require(found)
    #expect(sample.start == 30, "the longest turn, not the first")
    #expect(
        sample.end == 38,
        "capped, because nobody listens to thirty seconds to place a voice"
    )
    #expect(sample.audio.lastPathComponent == "recording.m4a")

    // A merged duplicate reads as the person it was merged into, so the
    // sample follows the same pointer every other read does.
    let duplicate = try await store.createPerson(name: "B. Baker")
    try await store.merge(ben.id, into: duplicate.id)
    let viaDuplicate = await runtime.voiceSample(of: duplicate.id, inMeeting: meetingID)
    _ = try #require(viaDuplicate)
}

@MainActor
private func noAudioMeansNoSample() async throws {
    let root = try TestPaths.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = RuntimeFixtures.makeRuntime(root: root)
    let store = try #require(runtime.speakerStore)
    let ben = try await store.createPerson(name: "Ben")
    let meetingID = try await PeopleFixtures.makeAppearance(
        store: store, identityID: ben.id, root: root,
        title: "Weekly sync", at: Date(timeIntervalSince1970: 1_787_900_000),
        turns: [(0, 20)], writingAudio: false
    )

    // Compaction removes the mixdown of an old meeting. The row stays, and
    // the button that would play nothing is not offered.
    let hasAudio = await runtime.appearances(of: ben.id).first?.hasAudio ?? true
    #expect(!hasAudio)
    let sample = await runtime.voiceSample(of: ben.id, inMeeting: meetingID)
    #expect(sample == nil)
}

/// Which person in the directory is the one at this Mac.
@Suite("LocalUser")
struct LocalUserTests {
    @Test("forgetting a voice takes the readings that built it")
    func forgettingAVoiceTakesTheReadingsThatBuiltIt() async throws {
        try await forgettingAVoiceTakesTheReadings()
    }

    @Test("merging your row into another one carries the flag to the survivor")
    func mergingYourRowIntoAnotherOneCarriesTheFlagToTheSurvivor() async throws {
        try await mergingYouCarriesTheFlag()
    }

    @Test("telling a row it is also you leaves one person with their real name")
    func tellingARowItIsAlsoYouLeavesOnePersonWithTheirRealName() async throws {
        try await tellingARowItIsAlsoYou()
    }
}

/// Slack names a huddle's participants and the microphone track is named
/// from nothing, so the same person routinely arrives as two rows. Folding
/// them together is what puts the mic-track voice and the platform's name
/// on one profile.
@MainActor
private func tellingARowItIsAlsoYou() async throws {
    let root = try TestPaths.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = RuntimeFixtures.makeRuntime(root: root)
    let store = try #require(runtime.speakerStore)

    await runtime.ensureLocalUserIdentity()
    let fromSlack = try await store.createPerson(name: "Andrew Neeser")
    let model = PeopleDirectoryModel(runtime: runtime)
    await model.reload()

    let row = try #require(model.entries.first { $0.id == fromSlack.id })
    #expect(model.canBeYou(row), "the row is not you yet")
    await model.makeYou(row)

    let localUser = try await store.localUser()
    #expect(localUser?.id == fromSlack.id)
    #expect(
        runtime.settings.localUserName == "Andrew Neeser",
        "the launch sync writes the cached name onto the flagged row, so it has to move too"
    )
    #expect(runtime.settings.processing.localUserIdentityID == fromSlack.id)
    let you = try #require(model.localUser)
    #expect(!model.canBeYou(you), "you cannot be told you are you")
}

/// A merge leaves the source as a tombstone, and the flag saying which row
/// is the person at this Mac has to move to the row that survives. Left
/// behind, the survivor is not you: the microphone track stops resolving to
/// a named person and the launch sync creates a second "Me".
@MainActor
private func mergingYouCarriesTheFlag() async throws {
    let root = try TestPaths.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = RuntimeFixtures.makeRuntime(root: root)
    let store = try #require(runtime.speakerStore)

    await runtime.ensureLocalUserIdentity()
    let existing = try await store.localUser()
    let me = try #require(existing)
    let fromSlack = try await store.createPerson(name: "Andrew Neeser")

    try await store.merge(me.id, into: fromSlack.id)

    let localUser = try await store.localUser()
    #expect(localUser?.id == fromSlack.id)
    let survivor = try await store.current(fromSlack.id)?.isLocalUser
    #expect(survivor ?? false)
}

/// A reading is kept so the vector it produced can be heard and re-derived,
/// which means forgetting the voice has to take it. Across the whole family:
/// vectors go for every identifier that reads as this person, and audio filed
/// under one that has since been merged away is still audio of them.
@MainActor
private func forgettingAVoiceTakesTheReadings() async throws {
    let root = try TestPaths.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = RuntimeFixtures.makeRuntime(root: root)
    let store = try #require(runtime.speakerStore)
    let old = try await store.createPerson(name: "Andrew")
    let current = try await store.createPerson(name: "Andrew Neeser")
    try await store.merge(old.id, into: current.id)

    let archive = runtime.voiceEnrollmentArchive
    let reading = try archive.newRecording(for: old.id, id: "take-one")
    try Data([0x00]).write(to: reading)
    #expect(archive.recordings(for: old.id).count == 1)

    await runtime.forgetVoice(of: current.id)

    #expect(
        archive.recordings(for: old.id).isEmpty,
        "the audio of a merged-away row is audio of the person it reads as"
    )
}

/// The schema as version 1 shipped it, frozen here on purpose.
///
/// A migration test that builds its fixture from the current source cannot
/// fail: the "old" database would gain every change alongside the migration
/// meant to introduce it. This copy stays as version 1 was.
private func writeVersionOneDatabase(at url: URL, name: String) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
        throw MigrationFixtureError.cannotOpen
    }
    defer { sqlite3_close(handle) }
    let sql = """
        PRAGMA foreign_keys=ON;
        CREATE TABLE identity(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          kind TEXT NOT NULL CHECK (kind IN ('person','anonymous')),
          display_name TEXT,
          anonymous_number INTEGER,
          organization TEXT,
          is_local_user INTEGER NOT NULL DEFAULT 0,
          state TEXT NOT NULL CHECK (state IN ('ephemeral','persistent')),
          merged_into INTEGER REFERENCES identity(id) ON DELETE SET NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          last_seen_at REAL
        );
        CREATE INDEX idx_identity_kind ON identity(kind, state);
        CREATE TABLE identity_alias(
          identity_id INTEGER NOT NULL REFERENCES identity(id) ON DELETE CASCADE,
          alias TEXT NOT NULL,
          PRIMARY KEY(identity_id, alias)
        );
        CREATE TABLE voice_embedding(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          identity_id INTEGER NOT NULL REFERENCES identity(id) ON DELETE CASCADE,
          model_identifier TEXT NOT NULL,
          embedding_dim INTEGER NOT NULL,
          embedding BLOB NOT NULL,
          quality_score REAL NOT NULL,
          speech_seconds REAL NOT NULL,
          source_type TEXT NOT NULL,
          source_meeting TEXT,
          is_human_verified INTEGER NOT NULL DEFAULT 1,
          created_at REAL NOT NULL
        );
        CREATE INDEX idx_embedding_identity ON voice_embedding(identity_id, model_identifier);
        CREATE TABLE derived_profile(
          identity_id INTEGER NOT NULL REFERENCES identity(id) ON DELETE CASCADE,
          model_identifier TEXT NOT NULL,
          centroid BLOB NOT NULL,
          embedding_dim INTEGER NOT NULL,
          sample_count INTEGER NOT NULL,
          recording_count INTEGER NOT NULL,
          speech_seconds REAL NOT NULL,
          updated_at REAL NOT NULL,
          PRIMARY KEY(identity_id, model_identifier)
        );
        CREATE TABLE speaker_occurrence(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          meeting_id TEXT NOT NULL,
          cluster_id TEXT NOT NULL,
          track TEXT NOT NULL,
          speech_seconds REAL NOT NULL,
          embedding BLOB,
          embedding_dim INTEGER,
          model_identifier TEXT,
          resolved_identity_id INTEGER REFERENCES identity(id) ON DELETE SET NULL,
          resolution_source TEXT NOT NULL,
          score REAL,
          runner_up_score REAL,
          margin REAL,
          threshold_band TEXT NOT NULL,
          human_verified INTEGER NOT NULL DEFAULT 0,
          expected_participant INTEGER NOT NULL DEFAULT 0,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          UNIQUE(meeting_id, cluster_id)
        );
        CREATE INDEX idx_occurrence_identity ON speaker_occurrence(resolved_identity_id);
        CREATE INDEX idx_occurrence_meeting ON speaker_occurrence(meeting_id);
        CREATE TABLE pending_enrollment(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          identity_id INTEGER NOT NULL REFERENCES identity(id) ON DELETE CASCADE,
          model_identifier TEXT NOT NULL,
          embedding BLOB NOT NULL,
          embedding_dim INTEGER NOT NULL,
          speech_seconds REAL NOT NULL,
          quality_score REAL NOT NULL,
          source_type TEXT NOT NULL,
          source_meeting TEXT,
          created_at REAL NOT NULL
        );
        CREATE INDEX idx_pending_identity ON pending_enrollment(identity_id, model_identifier);
        CREATE TABLE voice_evidence(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          voice_embedding_id INTEGER REFERENCES voice_embedding(id) ON DELETE CASCADE,
          pending_enrollment_id INTEGER REFERENCES pending_enrollment(id) ON DELETE CASCADE,
          meeting_id TEXT NOT NULL,
          track TEXT NOT NULL,
          confirmation_source TEXT NOT NULL,
          human_verified INTEGER NOT NULL DEFAULT 0,
          analysis_id TEXT,
          cluster_id TEXT,
          created_at REAL NOT NULL,
          CHECK ((voice_embedding_id IS NULL) <> (pending_enrollment_id IS NULL))
        );
        CREATE INDEX idx_evidence_embedding ON voice_evidence(voice_embedding_id);
        CREATE INDEX idx_evidence_pending ON voice_evidence(pending_enrollment_id);
        CREATE INDEX idx_evidence_meeting ON voice_evidence(meeting_id, track);
        CREATE TABLE voice_evidence_span(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          evidence_id INTEGER NOT NULL REFERENCES voice_evidence(id) ON DELETE CASCADE,
          start_time REAL NOT NULL,
          end_time REAL NOT NULL,
          contradicted INTEGER NOT NULL DEFAULT 0,
          CHECK (end_time >= start_time)
        );
        CREATE INDEX idx_span_evidence ON voice_evidence_span(evidence_id);
        INSERT INTO identity(kind, display_name, is_local_user, state, created_at, updated_at)
        VALUES('person', '\(name)', 0, 'persistent', 0, 0);
        PRAGMA user_version = 1;
        """
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
        throw MigrationFixtureError.schemaFailed(String(cString: sqlite3_errmsg(handle)))
    }
}

private enum MigrationFixtureError: Error {
    case cannotOpen
    case schemaFailed(String)
}

// MARK: - the picker popover

/// A wheel scroll slides rows under a cursor that never moved, so the row
/// beneath it changes and hover highlights it. Scrolling to that highlight
/// puts the row back where it started and the gesture goes nowhere, which
/// is why the list follows the arrow keys and a narrowed query but not the
/// pointer.
@MainActor
private func aHoveredRowDoesNotScrollTheList() {
    let picker = PeoplePickerModel()
    picker.moveHighlight(to: IdentityID(1), follow: true)
    let arrowed = picker.follows

    picker.moveHighlight(to: IdentityID(2), follow: false)
    #expect(picker.highlight == IdentityID(2), "hover still highlights the row it lands on")
    #expect(picker.follows == arrowed, "and the list stays where the scroll put it")

    picker.moveHighlight(to: IdentityID(1), follow: true)
    #expect(
        picker.follows == arrowed + 1,
        "arrowing back to the row hover left behind still scrolls to it"
    )
}

// MARK: - the right-click menu

/// A right-click on a row that is not selected acts on that row. Acting on
/// the selection instead would delete somebody the pointer was never over.
@MainActor
private func aRightClickActsOnTheRowUnderIt() async throws {
    let root = try TestPaths.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = PeopleDirectoryModel(runtime: RuntimeFixtures.makeRuntime(root: root))
    model.entries = [
        entry(1, name: "Chris Fowler"),
        entry(2, name: "Dana Kwon"),
        entry(3, name: "Priya Raman"),
    ]
    model.select(IdentityID(1), extending: false)

    #expect(
        model.contextTargets(for: model.entries[1]).map(\.id) == [IdentityID(2)],
        "the row under the pointer"
    )

    model.select(IdentityID(2), extending: true)
    #expect(
        Set(model.contextTargets(for: model.entries[1]).map(\.id))
            == [IdentityID(1), IdentityID(2)],
        "and a row inside the selection acts on all of it"
    )

    model.confirmDelete(model.contextTargets(for: model.entries[1]))
    let pending = try #require(model.pendingAction)
    #expect(pending.kind == .delete)
    #expect(Set(pending.targets) == [IdentityID(1), IdentityID(2)])
    #expect(pending.title == "Delete 2 people?")
}
