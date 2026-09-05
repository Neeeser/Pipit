import Foundation
import PipitCore
import PipitServices
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
        let folder = try store.create(name: "Northwind Daily", about: "The weekday standup")
        #expect(folder.name == "Northwind Daily")
        #expect(store.exists("Northwind Daily"))
        let manifest = root
            .appendingPathComponent("Folders/Northwind Daily/folder.json")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        #expect(store.folder(named: "Northwind Daily")?.about == "The weekday standup")
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
        try store.create(name: "Fen Trust", about: "Client work")
        let created = try Self.meeting(repository, title: "Kickoff")
        try repository.move(meetingID: created.id, toFolder: "Fen Trust")
        try store.rename("Fen Trust", to: "Fenwick Trust")

        #expect(!store.exists("Fen Trust"))
        #expect(store.folder(named: "Fenwick Trust")?.about == "Client work")
        #expect(repository.meetings(inFolder: "Fenwick Trust").count == 1)
        // The directory moved with the folder, and the identifier still
        // reaches it.
        #expect(repository.findMeeting(id: created.id)?.metadata.id == created.id)
    }

    @Test("filing a meeting moves its directory and records where it went")
    func filingAMeetingMovesItsDirectoryAndRecordsWhereItWent() async throws {
        let (root, repository, store) = try Self.archive()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.create(name: "Northwind Daily")
        let created = try Self.meeting(repository, title: "Northwind Daily")
        let before = repository.findMeeting(id: created.id)?.store.layout.root
        #expect(before?.path.contains("/2026/08/") == true, "starts under the month")

        let moved = try repository.move(meetingID: created.id, toFolder: "Northwind Daily")
        #expect(moved.deletingLastPathComponent().lastPathComponent == "Northwind Daily")
        #expect(moved.lastPathComponent == "Northwind Daily (Aug 18, 11:31 AM)")
        let found = repository.findMeeting(id: created.id)
        #expect(found?.store.layout.root == moved)
        #expect(found?.metadata.folderName == "Northwind Daily")
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
        try store.create(name: "Northwind Daily")
        let created = try Self.meeting(repository, title: "Huddle in #eng")
        try repository.move(meetingID: created.id, toFolder: "Northwind Daily")

        guard let found = repository.findMeeting(id: created.id) else {
            Issue.record("the meeting went missing")
            return
        }
        _ = try found.store.updateMetadata { $0.titles.human = "Northwind Daily" }
        guard let settled = repository.settleFolderName(
            for: repository.findMeeting(id: created.id)!.metadata
        ) else {
            Issue.record("nothing settled")
            return
        }

        #expect(settled.lastPathComponent == "Northwind Daily (Aug 18, 11:31 AM)")
        #expect(
            settled.deletingLastPathComponent().lastPathComponent == "Northwind Daily",
            "renaming must not drag it back to the month"
        )
        #expect(repository.findMeeting(id: created.id)?.metadata.folderName == "Northwind Daily")
    }

    @Test("deleting a folder that still holds an unlistable meeting is refused")
    @MainActor
    func deletingAFolderThatStillHoldsAnUnlistableMeetingIsRefused() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Meetings")
        let repository = MeetingRepository(root: archive)
        let store = MeetingFolderStore(root: archive)
        try store.create(name: "Tudor")
        let listed = try Self.meeting(repository, title: "Kickoff")
        try repository.move(meetingID: listed.id, toFolder: "Tudor")

        // A meeting whose metadata does not decode is not listed, so nothing
        // moves it out of the folder before the folder is taken away.
        let corrupt = archive.appendingPathComponent("Folders/Tudor/Unreadable")
        try FileManager.default.createDirectory(
            at: corrupt.appendingPathComponent("raw"), withIntermediateDirectories: true
        )
        try "{".write(
            to: corrupt.appendingPathComponent("raw/metadata.json"),
            atomically: true, encoding: .utf8
        )
        let segment = corrupt.appendingPathComponent("raw/segments/000.caf")
        try FileManager.default.createDirectory(
            at: segment.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data([0x01, 0x02, 0x03]).write(to: segment)

        let runtime = RuntimeFixtures.makeRuntime(root: root)
        let failures = runtime.deleteFolder("Tudor")

        // The meeting that could be listed went back to its month.
        #expect(repository.findMeeting(id: listed.id)?.store.layout.root.path.contains("/2026/08/") == true)
        // The one that could not is still there, with its audio.
        #expect(store.exists("Tudor"))
        #expect(FileManager.default.fileExists(atPath: corrupt.path))
        #expect(FileManager.default.fileExists(atPath: segment.path))
        #expect(failures.count == 1)
        guard let refusal = failures["Tudor"] as? MeetingFolderError else {
            Issue.record("the folder was removed, or refused for another reason")
            return
        }
        #expect(refusal == .folderNotEmpty(name: "Tudor", remaining: ["Unreadable"]))
    }

    @Test("a folder holding nothing but its manifest is deleted")
    func aFolderHoldingNothingButItsManifestIsDeleted() async throws {
        let (root, repository, store) = try Self.archive()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.create(name: "Tudor")
        let created = try Self.meeting(repository, title: "Kickoff")
        try repository.move(meetingID: created.id, toFolder: "Tudor")
        try repository.move(meetingID: created.id, toFolder: nil)

        try store.delete("Tudor")
        #expect(!store.exists("Tudor"))
        #expect(throws: MeetingFolderError.folderNotFound("Gone")) {
            try store.delete("Gone")
        }
    }

}
