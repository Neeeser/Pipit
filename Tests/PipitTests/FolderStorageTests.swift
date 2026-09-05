import Foundation
import PipitCore
import PipitTestSupport
import Testing

/// Filing a meeting moves its directory. These pin what has to survive that:
/// the identifier, the listing, and the agreement between where a meeting sits
/// and what its metadata says about where it sits.
@Suite("Folder storage")
struct FolderStorageTests {
    private static func archive() throws -> (root: URL, repository: MeetingRepository, folders: MeetingFolderStore) {
        let root = try TestPaths.makeTemporaryDirectory()
        return (root, MeetingRepository(root: root), MeetingFolderStore(root: root))
    }

    private static func meeting(
        _ repository: MeetingRepository, title: String, hour: Int = 11, minute: Int = 31,
        day: Int = 18
    ) throws -> MeetingMetadata {
        let started = MeetingFolderNameTests.date(
            year: 2026, month: 8, day: day, hour: hour, minute: minute
        )
        let created = try repository.createMeeting(
            source: .slackHuddle, provider: .slack, startedAt: started,
            titles: TitleCandidates(provider: title, timestampFallback: "f"), now: started
        )
        return try created.store.updateMetadata { $0.processing = ProcessingStatus(state: .complete) }
    }

    @Test("a new folder is a directory with a manifest beside its meetings")
    func aNewFolderIsADirectoryWithAManifestBesideItsMeetings() async throws {
        let (root, _, store) = try Self.archive()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try store.create(name: "Hindsight Daily", about: "The weekday standup")
        #expect(folder.name == "Hindsight Daily")
        #expect(store.exists("Hindsight Daily"))
        let manifest = root
            .appendingPathComponent("Folders/Hindsight Daily/folder.json")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        #expect(store.folder(named: "Hindsight Daily")?.about == "The weekday standup")
    }

    @Test("a folder somebody made in Finder is still a folder")
    func aFolderSomebodyMadeInFinderIsStillAFolder() async throws {
        let (root, _, store) = try Self.archive()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Folders/Made By Hand"),
            withIntermediateDirectories: true
        )
        #expect(store.folders().map(\.name) == ["Made By Hand"])
        #expect(store.folder(named: "Made By Hand")?.filesAutomatically == false)
    }

    @Test("a name already taken, and a name that is not a name, are refused")
    func aNameAlreadyTakenAndANameThatIsNotANameAreRefused() async throws {
        let (root, _, store) = try Self.archive()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.create(name: "Tudor")
        #expect(throws: MeetingFolderError.folderExists("Tudor")) {
            try store.create(name: "Tudor")
        }
        #expect(throws: MeetingFolderError.invalidFolderName("   ")) {
            try store.create(name: "   ")
        }
        #expect(throws: MeetingFolderError.invalidFolderName("Folders")) {
            try store.create(name: "Folders")
        }
    }

    @Test("renaming a folder moves the directory and keeps what it holds")
    func renamingAFolderMovesTheDirectoryAndKeepsWhatItHolds() async throws {
        let (root, repository, store) = try Self.archive()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.create(name: "Cap One", about: "Client work")
        let created = try Self.meeting(repository, title: "Kickoff")
        try repository.move(meetingID: created.id, toFolder: "Cap One")
        try store.rename("Cap One", to: "Capital One")

        #expect(!store.exists("Cap One"))
        #expect(store.folder(named: "Capital One")?.about == "Client work")
        #expect(repository.meetings(inFolder: "Capital One").count == 1)
        // The directory moved with the folder, and the identifier still
        // reaches it.
        #expect(repository.findMeeting(id: created.id)?.metadata.id == created.id)
    }

    @Test("filing a meeting moves its directory and records where it went")
    func filingAMeetingMovesItsDirectoryAndRecordsWhereItWent() async throws {
        let (root, repository, store) = try Self.archive()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.create(name: "Hindsight Daily")
        let created = try Self.meeting(repository, title: "Hindsight Daily")
        let before = repository.findMeeting(id: created.id)?.store.layout.root
        #expect(before?.path.contains("/2026/08/") == true, "starts under the month")

        let moved = try repository.move(meetingID: created.id, toFolder: "Hindsight Daily")
        #expect(moved.deletingLastPathComponent().lastPathComponent == "Hindsight Daily")
        #expect(moved.lastPathComponent == "Hindsight Daily (Aug 18, 11:31 AM)")
        let found = repository.findMeeting(id: created.id)
        #expect(found?.store.layout.root == moved)
        #expect(found?.metadata.folderName == "Hindsight Daily")
        #expect(found?.metadata.id == created.id, "the identifier did not change")
        #expect(repository.listMeetings().count == 1, "still one meeting, once")
    }

    @Test("taking a meeting out puts it back under the month it was recorded")
    func takingAMeetingOutPutsItBackUnderTheMonthItWasRecorded() async throws {
        let (root, repository, store) = try Self.archive()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.create(name: "Tudor")
        let created = try Self.meeting(repository, title: "Tudor Meeting 2")
        try repository.move(meetingID: created.id, toFolder: "Tudor")
        let out = try repository.move(meetingID: created.id, toFolder: nil)

        #expect(out.path.contains("/2026/08/"), "got \(out.path)")
        let found = repository.findMeeting(id: created.id)
        #expect(found?.metadata.folderName == nil)
        #expect(found?.metadata.removedFromFolders == ["Tudor"])
        #expect(repository.meetings(inFolder: "Tudor").count == 0)
    }

    @Test("a meeting still being processed is not moved")
    func aMeetingStillBeingProcessedIsNotMoved() async throws {
        let (root, repository, store) = try Self.archive()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.create(name: "Tudor")
        let started = MeetingFolderNameTests.date(
            year: 2026, month: 8, day: 18, hour: 9, minute: 0
        )
        let created = try repository.createMeeting(
            source: .slackHuddle, provider: .slack, startedAt: started, now: started
        )
        #expect(throws: MeetingFolderError.meetingIsBusy(created.metadata.id)) {
            try repository.move(meetingID: created.metadata.id, toFolder: "Tudor")
        }

        let done = try Self.meeting(repository, title: "Finished", hour: 15)
        #expect(throws: MeetingFolderError.folderNotFound("Nowhere")) {
            try repository.move(meetingID: done.id, toFolder: "Nowhere")
        }
        #expect(throws: MeetingFolderError.meetingNotFound("nobody")) {
            try repository.move(meetingID: "nobody", toFolder: "Tudor")
        }
    }

    @Test("a filed meeting renamed by enrichment stays in its folder")
    func aFiledMeetingRenamedByEnrichmentStaysInItsFolder() async throws {
        let (root, repository, store) = try Self.archive()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.create(name: "Hindsight Daily")
        let created = try Self.meeting(repository, title: "Huddle in #eng")
        try repository.move(meetingID: created.id, toFolder: "Hindsight Daily")

        guard let found = repository.findMeeting(id: created.id) else {
            Issue.record("the meeting went missing")
            return
        }
        _ = try found.store.updateMetadata { $0.titles.human = "Hindsight Daily" }
        guard let settled = repository.settleFolderName(
            for: repository.findMeeting(id: created.id)!.metadata
        ) else {
            Issue.record("nothing settled")
            return
        }

        #expect(settled.lastPathComponent == "Hindsight Daily (Aug 18, 11:31 AM)")
        #expect(
            settled.deletingLastPathComponent().lastPathComponent == "Hindsight Daily",
            "renaming must not drag it back to the month"
        )
        #expect(repository.findMeeting(id: created.id)?.metadata.folderName == "Hindsight Daily")
    }

}
