import Foundation
import PipitCore
import PipitServices
import PipitUI
import Testing

// The caches that let the meetings window open without parsing every file in
// the archive. Each is only safe if a changed file is never answered from the
// old read, so most of these check that.

@Suite("FileReadCache")
struct FileReadCacheTests {
    private final class Counter: @unchecked Sendable {
        var reads = 0
    }

    private func read(_ cache: FileReadCache<String>, _ url: URL, counting counter: Counter) throws -> String {
        try cache.value(at: url.path) {
            counter.reads += 1
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    @Test("an unchanged file is read once")
    func anUnchangedFileIsReadOnce() throws {
        let url = try TestPaths.makeTemporaryDirectory().appendingPathComponent("notes.md")
        try AtomicFile.writeText("first", to: url)
        let cache = FileReadCache<String>()
        let counter = Counter()
        #expect(try read(cache, url, counting: counter) == "first")
        #expect(try read(cache, url, counting: counter) == "first")
        #expect(counter.reads == 1)
    }

    @Test("a rewritten file is read again, even at the same size")
    func aRewrittenFileIsReadAgain() throws {
        let url = try TestPaths.makeTemporaryDirectory().appendingPathComponent("notes.md")
        try AtomicFile.writeText("first", to: url)
        let cache = FileReadCache<String>()
        let counter = Counter()
        _ = try read(cache, url, counting: counter)
        try AtomicFile.writeText("again", to: url)
        #expect(try read(cache, url, counting: counter) == "again")
        #expect(counter.reads == 2)
    }

    @Test("a saved cache drops entries whose files changed, and a new format drops it all")
    func aSavedCacheIsCheckedOnTheWayOut() throws {
        let folder = try TestPaths.makeTemporaryDirectory()
        let kept = folder.appendingPathComponent("kept.md")
        let changed = folder.appendingPathComponent("changed.md")
        try AtomicFile.writeText("kept", to: kept)
        try AtomicFile.writeText("before", to: changed)
        let cache = FileReadCache<String>()
        let counter = Counter()
        _ = try read(cache, kept, counting: counter)
        _ = try read(cache, changed, counting: counter)
        try AtomicFile.writeText("after", to: changed)
        let saved = try cache.encoded(format: 1)

        let restored = FileReadCache<String>()
        #expect(restored.restore(from: saved, format: 1) == 1, "only the unchanged file's entry")
        let fresh = Counter()
        #expect(try read(restored, kept, counting: fresh) == "kept")
        #expect(fresh.reads == 0, "answered from the saved copy")
        #expect(try read(restored, changed, counting: fresh) == "after")

        #expect(FileReadCache<String>().restore(from: saved, format: 2) == 0)
    }
}

@Suite("Meetings list caches")
struct MeetingsListCacheTests {
    /// A speaker map written after the list was read has to reach the next
    /// read, which is what renaming a speaker does.
    @Test("a renamed speaker reaches the list after it was cached")
    @MainActor
    func aRenamedSpeakerReachesTheCachedList() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(root: root, clusters: ["remote-001_speaker_00"])
        let runtime = RuntimeFixtures.makeRuntime(root: root)
        let before = await runtime.meetingRows()
        #expect(before.first?.namedSpeakers.isEmpty == true)

        var map = SpeakerMap()
        map.assign("Avery Quinn", to: "remote-001_speaker_00")
        try meeting.store.writeSpeakerMap(map)
        let after = await runtime.meetingRows()
        #expect(after.first?.namedSpeakers.map(\.displayName) == ["Avery Quinn"])
    }

    /// The speakers read from each transcript are saved, so the first list
    /// after a launch does not parse every transcript again.
    @Test("the transcript speakers are saved for the next launch")
    @MainActor
    func theTranscriptSpeakersAreSaved() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00", "remote-001_speaker_01"])
        let runtime = RuntimeFixtures.makeRuntime(root: root)
        let rows = await runtime.meetingRows()
        // The folder as the listing named it, which is the key the cache uses.
        let listed = try #require(rows.first?.summary.directory)
        let file = runtime.transcriptSpeakersCacheFile
        let data = try Data(contentsOf: file)

        let restored = FileReadCache<[TranscriptSpeaker]>()
        #expect(restored.restore(from: data, format: MeetingStore.transcriptSpeakersFormat) >= 1)
        let path = MeetingLayout(root: listed).canonicalTranscript.path
        let keys = restored.value(at: path) { [] }.map(\.key)
        #expect(keys.contains("remote-001_speaker_00"))
        #expect(keys.contains("remote-001_speaker_01"))
    }

    /// The window drew an empty list and "No Meeting Selected" for the moment
    /// its first read took, every time it opened. The meeting itself opens a
    /// frame later, so the window appears before it has been read.
    @Test("a new window starts from the last list, with a meeting chosen and then opened")
    @MainActor
    func aNewWindowStartsFromTheLastList() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(root: root, clusters: ["local"])
        let runtime = RuntimeFixtures.makeRuntime(root: root)
        let early = MeetingsWindowModel(runtime: runtime)
        early.showLastList()
        #expect(early.rows.isEmpty, "nothing read yet")

        _ = await runtime.meetingRows()
        let model = MeetingsWindowModel(runtime: runtime)
        #expect(model.rows.isEmpty, "the window's first frame is drawn empty")
        model.showLastList()
        #expect(model.rows.map(\.id) == [meeting.id])
        #expect(!model.isLoading)
        #expect(model.selection == [meeting.id], "chosen before any reload")
        #expect(model.detail == nil, "and not read yet, so the window is not held up by it")
        for _ in 0..<100 where model.detail == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.detail?.meetingID == meeting.id, "opened without a reload")
    }

    /// Until the speakers are looked up, an empty strip is not "nobody
    /// spoke", and saying so flickered on every click.
    @Test("the speaker strip waits for its first lookup")
    @MainActor
    func theSpeakerStripWaitsForItsFirstLookup() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(root: root, clusters: ["remote-001_speaker_00"])
        let detail = MeetingReviewModel(runtime: RuntimeFixtures.makeRuntime(root: root), meetingID: meeting.id)
        #expect(!detail.hasReadSpeakers)
        await detail.reloadSpeakers()
        #expect(detail.hasReadSpeakers)
        #expect(detail.speakerRows.count == 1)
    }
}

@Suite("Meetings search by bytes")
struct MeetingsSearchBytesTests {
    private func row(_ id: String) -> MeetingRow {
        MeetingRow(
            summary: MeetingSummary(
                id: id, directory: URL(fileURLWithPath: "/tmp/\(id)"), title: "Weekly sync",
                startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 60, source: .googleMeet,
                provider: .unknown, processingState: .complete, wasInterrupted: false, hasTranscript: true
            ),
            speakers: [], notes: ""
        )
    }

    /// The transcript search compares bytes, so it has to find what the
    /// character search found: words anywhere in the text, accented ones
    /// included, and nothing that is not there.
    @Test("a transcript word is found anywhere, accents included, and a missing one is not")
    func aTranscriptWordIsFound() {
        let meeting = row("m1")
        let transcript = "we moved the café launch to thursday after the budget review"
        #expect(MeetingsDirectoryFilter.matches(meeting, query: "Budget", transcript: transcript))
        #expect(MeetingsDirectoryFilter.matches(meeting, query: "café", transcript: transcript))
        #expect(MeetingsDirectoryFilter.matches(meeting, query: "launch to thurs", transcript: transcript))
        #expect(!MeetingsDirectoryFilter.matches(meeting, query: "roadmap", transcript: transcript))
        #expect(!MeetingsDirectoryFilter.matches(meeting, query: "budgets", transcript: transcript))
    }
}

@Suite("Meetings search index")
struct MeetingsSearchIndexTests {
    /// The index is every transcript in the archive held in memory, so a
    /// window that is opened and closed without a search should never read it.
    @Test("the index is read on the first search, not when the window opens")
    @MainActor
    func theIndexWaitsForASearch() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(root: root, clusters: ["local"], title: "Design review")
        try meeting.store.writeTranscriptMarkdown("Marlow: the northwind renewal")
        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!model.searchesTranscripts)
        #expect(!model.indexHolds(meeting.id))

        model.query = "northwind"
        for _ in 0..<200 where !model.searchesTranscripts { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.indexHolds(meeting.id))
        #expect(model.sections.flatMap(\.rows).map(\.id) == [meeting.id])
    }
}
