import Foundation
import PipitCore
import Testing

/// The folder a meeting lives in is named for the meeting, and the identifier
/// it is known by never changes. These pin the seam between those two facts.
@Suite("Meeting folder renaming")
struct MeetingFolderRenameTests {
    private static func complete(_ store: MeetingStore) throws -> MeetingMetadata {
        try store.updateMetadata { $0.processing = ProcessingStatus(state: .complete) }
    }

    @Test("a new meeting is filed under a readable name, not its identifier")
    func aNewMeetingIsFiledUnderAReadableNameNotItsIdentifier() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let started = MeetingFolderNameTests.date(
            year: 2026, month: 8, day: 18, hour: 9, minute: 2
        )
        let created = try repository.createMeeting(
            source: .slackHuddle, provider: .slack, startedAt: started,
            titles: TitleCandidates(provider: "Hindsight Daily", timestampFallback: "f"),
            now: started
        )
        let name = created.store.layout.root.lastPathComponent
        #expect(name == "Hindsight Daily (Aug 18, 9:02 AM)")
        #expect(created.metadata.directoryName == name)
        #expect(name != created.metadata.id, "the folder is not the identifier")
        #expect(created.metadata.id.hasSuffix("slack-huddle-hindsight-daily"), "got \(created.metadata.id)")
    }

    @Test("a meeting is found after its folder no longer matches its identifier")
    func aMeetingIsFoundAfterItsFolderNoLongerMatchesItsIdentifier() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let started = MeetingFolderNameTests.date(
            year: 2026, month: 8, day: 18, hour: 14, minute: 18
        )
        let created = try repository.createMeeting(
            source: .zoom, provider: .zoom, startedAt: started,
            titles: TitleCandidates(provider: "Weekly sync", timestampFallback: "f"),
            now: started
        )
        let found = repository.findMeeting(id: created.metadata.id)
        #expect(found?.metadata.id == created.metadata.id)
        // Again, to exercise the cache rather than the first scan.
        #expect(repository.findMeeting(id: created.metadata.id)?.store.layout.root == created.store.layout.root)
        #expect(repository.findMeeting(id: "no-such-meeting") == nil)
    }

    @Test("a completed meeting takes the title enrichment gave it")
    func aCompletedMeetingTakesTheTitleEnrichmentGaveIt() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let started = MeetingFolderNameTests.date(
            year: 2026, month: 8, day: 20, hour: 15, minute: 14
        )
        let created = try repository.createMeeting(
            source: .manual, provider: .unknown, startedAt: started, now: started
        )
        #expect(created.store.layout.root.lastPathComponent == "Manual recording (Aug 20, 3:14 PM)")

        _ = try created.store.updateMetadata { $0.titles.ai = "Pricing model rework" }
        let ready = try Self.complete(created.store)
        let settled = repository.settleFolderName(for: ready)
        #expect(settled?.lastPathComponent == "Pricing model rework (Aug 20, 3:14 PM)")

        let found = repository.findMeeting(id: created.metadata.id)
        #expect(found?.metadata.id == created.metadata.id)
        #expect(found?.metadata.directoryName == "Pricing model rework (Aug 20, 3:14 PM)")
        #expect(
            !FileManager.default.fileExists(atPath: created.store.layout.root.path),
            "the old folder should be gone"
        )
    }

    @Test("settling twice moves the folder once")
    func settlingTwiceMovesTheFolderOnce() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let started = MeetingFolderNameTests.date(
            year: 2026, month: 8, day: 20, hour: 15, minute: 14
        )
        let created = try repository.createMeeting(
            source: .manual, provider: .unknown, startedAt: started, now: started
        )
        _ = try created.store.updateMetadata { $0.titles.ai = "Retro" }
        let ready = try Self.complete(created.store)

        let first = repository.settleFolderName(for: ready)
        let second = repository.settleFolderName(for: ready)
        #expect(first?.lastPathComponent == "Retro (Aug 20, 3:14 PM)")
        #expect(second?.lastPathComponent == "Retro (Aug 20, 3:14 PM)")

        let month = root
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("08", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(
            at: month, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        #expect(entries.count == 1, "got \(entries.map(\.lastPathComponent))")
    }

    @Test("changing only the case of a title does not add a suffix")
    func changingOnlyTheCaseOfATitleDoesNotAddASuffix() async throws {
        // `fileExists` on a case-insensitive volume matches the folder's
        // own name, so the folder collided with itself and every settle
        // appended another number.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let started = MeetingFolderNameTests.date(
            year: 2026, month: 8, day: 18, hour: 9, minute: 0
        )
        let created = try repository.createMeeting(
            source: .slackHuddle, provider: .slack, startedAt: started,
            titles: TitleCandidates(provider: "standup", timestampFallback: "f"),
            now: started
        )
        _ = try created.store.updateMetadata { $0.titles.human = "Standup" }
        let ready = try Self.complete(created.store)

        let settled = repository.settleFolderName(for: ready)
        #expect(settled?.lastPathComponent == "Standup (Aug 18, 9:00 AM)")
    }

    @Test("a folder renamed by hand is left alone")
    func aFolderRenamedByHandIsLeftAlone() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let started = MeetingFolderNameTests.date(
            year: 2026, month: 8, day: 20, hour: 15, minute: 14
        )
        let created = try repository.createMeeting(
            source: .manual, provider: .unknown, startedAt: started, now: started
        )
        _ = try created.store.updateMetadata { $0.titles.ai = "Retro" }
        _ = try Self.complete(created.store)

        let mine = created.store.layout.root
            .deletingLastPathComponent()
            .appendingPathComponent("My own name", isDirectory: true)
        try FileManager.default.moveItem(at: created.store.layout.root, to: mine)

        let reread = try MeetingStore(layout: MeetingLayout(root: mine)).readMetadata()
        let settled = repository.settleFolderName(for: reread)
        #expect(settled?.lastPathComponent == "My own name")
        #expect(FileManager.default.fileExists(atPath: mine.path), "the hand-picked name should survive")
    }

    @Test("a meeting recorded before this change keeps its folder")
    func aMeetingRecordedBeforeThisChangeKeepsItsFolder() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let started = MeetingFolderNameTests.date(
            year: 2026, month: 8, day: 20, hour: 15, minute: 14
        )
        // The old shape: the folder is named for the identifier and the
        // metadata records no folder name.
        let id = "2026-08-20-1514-manual"
        let directory = MeetingArchiveLayout(root: root)
            .directory(named: id, startedAt: started)
        let store = MeetingStore(layout: MeetingLayout(root: directory))
        try store.createDirectories()
        var metadata = MeetingMetadata(
            id: id, source: .manual, provider: .unknown,
            createdAt: started, startedAt: started,
            titles: TitleCandidates(ai: "Retro", timestampFallback: "f")
        )
        metadata.processing = ProcessingStatus(state: .complete)
        try store.writeMetadata(metadata)

        #expect(repository.findMeeting(id: id)?.metadata.id == id)
        let settled = repository.settleFolderName(for: metadata)
        #expect(settled?.lastPathComponent == id)
    }

    @Test("two meetings sharing a title and a minute get separate folders")
    func twoMeetingsSharingATitleAndAMinuteGetSeparateFolders() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let started = MeetingFolderNameTests.date(
            year: 2026, month: 8, day: 18, hour: 9, minute: 2
        )
        let titles = TitleCandidates(provider: "Hindsight Daily", timestampFallback: "f")
        let first = try repository.createMeeting(
            source: .slackHuddle, provider: .slack, startedAt: started,
            titles: titles, now: started
        )
        let second = try repository.createMeeting(
            source: .slackHuddle, provider: .slack, startedAt: started,
            titles: titles, now: started
        )

        #expect(first.store.layout.root.lastPathComponent == "Hindsight Daily (Aug 18, 9:02 AM)")
        #expect(second.store.layout.root.lastPathComponent == "Hindsight Daily (Aug 18, 9:02 AM) 2")
        #expect(first.metadata.id != second.metadata.id, "identifiers collided: \(first.metadata.id)")
        #expect(repository.findMeeting(id: second.metadata.id)?.store.layout.root == second.store.layout.root)
    }

    @Test("the startup sweep settles a meeting the pipeline never revisits")
    func theStartupSweepSettlesAMeetingThePipelineNeverRevisits() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let started = MeetingFolderNameTests.date(
            year: 2026, month: 8, day: 20, hour: 15, minute: 14
        )
        let created = try repository.createMeeting(
            source: .manual, provider: .unknown, startedAt: started, now: started
        )
        _ = try created.store.updateMetadata { $0.titles.ai = "Board prep" }
        _ = try Self.complete(created.store)

        repository.settleFolderNames()
        #expect(repository.findMeeting(id: created.metadata.id)?
                .store.layout.root.lastPathComponent == "Board prep (Aug 20, 3:14 PM)")
    }

    @Test("a recording folded into another one stays where it is")
    func aRecordingFoldedIntoAnotherOneStaysWhereItIs() async throws {
        // It is folded in after its own pipeline run, so renaming it
        // would strand the path held by whatever folded it.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let started = MeetingFolderNameTests.date(
            year: 2026, month: 8, day: 18, hour: 12, minute: 20
        )
        let created = try repository.createMeeting(
            source: .zoom, provider: .zoom, startedAt: started,
            titles: TitleCandidates(provider: "Weekly sync", timestampFallback: "f"),
            now: started
        )
        let name = created.store.layout.root.lastPathComponent
        _ = try created.store.updateMetadata {
            $0.titles.ai = "Something else entirely"
            $0.mergedIntoMeetingID = "an-earlier-meeting"
            $0.processing = ProcessingStatus(state: .complete)
        }

        let reread = try created.store.readMetadata()
        #expect(repository.settleFolderName(for: reread)?.lastPathComponent == name)
        #expect(
            FileManager.default.fileExists(atPath: created.store.layout.root.path),
            "the folder the caller is holding should still be there"
        )
    }

    @Test("archive usage counts the bytes and the meetings a person can see")
    func archiveUsageCountsTheBytesAndTheMeetingsAPersonCanSee() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let started = MeetingFolderNameTests.date(
            year: 2026, month: 8, day: 18, hour: 9, minute: 2
        )
        let first = try repository.createMeeting(
            source: .slackHuddle, provider: .slack, startedAt: started,
            titles: TitleCandidates(provider: "One", timestampFallback: "f"), now: started
        )
        let second = try repository.createMeeting(
            source: .slackHuddle, provider: .slack,
            startedAt: started.addingTimeInterval(3_600),
            titles: TitleCandidates(provider: "Two", timestampFallback: "f"),
            now: started
        )
        let folded = try repository.createMeeting(
            source: .slackHuddle, provider: .slack,
            startedAt: started.addingTimeInterval(7_200),
            titles: TitleCandidates(provider: "Three", timestampFallback: "f"),
            now: started
        )
        _ = try folded.store.updateMetadata {
            $0.mergedIntoMeetingID = first.metadata.id
        }

        let payload = Data(repeating: 0, count: 40_000)
        try payload.write(to: first.store.layout.recordingAudio)
        try payload.write(to: second.store.layout.recordingAudio)

        let usage = repository.usage()
        #expect(usage.meetingCount == 2, "a folded recording is part of a meeting, not a meeting")
        #expect(usage.bytes >= 80_000, "should hold both recordings, got \(usage.bytes)")
        #expect((usage.freeBytes ?? 0) > 0, "the volume should report free space")
    }

    @Test("a meeting still recording is not renamed by the sweep")
    func aMeetingStillRecordingIsNotRenamedByTheSweep() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let started = MeetingFolderNameTests.date(
            year: 2026, month: 8, day: 20, hour: 15, minute: 14
        )
        let created = try repository.createMeeting(
            source: .manual, provider: .unknown, startedAt: started, now: started
        )
        _ = try created.store.updateMetadata { $0.titles.ai = "Board prep" }

        repository.settleFolderNames()
        #expect(repository.findMeeting(id: created.metadata.id)?
                .store.layout.root.lastPathComponent == "Manual recording (Aug 20, 3:14 PM)")
    }

}
