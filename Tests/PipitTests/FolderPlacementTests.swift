import Foundation
import PipitCore
import PipitIntegrations
import PipitServices
import Testing

/// Where a finished meeting ends up, run through the pipeline that decides it.
///
/// The matcher is tested on its own; these pin the seam around it. What is sent
/// to the model, what is written to disk, and the one rule that matters most:
/// a model's answer is recorded and never acted on.
@Suite("Folder placement")
struct FolderPlacementTests {
    private static func processed(
        root: URL, backend: FakeAIBackend, settings: AppSettings
    ) async throws -> (metadata: MeetingMetadata, repository: MeetingRepository) {
        let meeting = try PipelineFixtures.makeRecordedMeeting(root: root, seconds: 6)
        backend.transcriptionSegments = [
            RawTranscriptSegment(start: 0, end: 5, text: "The security review is still open.", speaker: "speaker_0")
        ]
        backend.diarizationSegments = backend.transcriptionSegments
        let pipeline = PipelineFixtures.makePipeline(
            repository: meeting.repository, backend: backend, settings: settings
        )
        await pipeline.process(meetingID: meeting.metadata.id)
        return (meeting.metadata, meeting.repository)
    }

    @Test("a folder rule files a matching meeting on its own")
    func aFolderRuleFilesAMatchingMeetingOnItsOwn() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = MeetingFolderStore(root: root)
        var folder = try folders.create(name: "Weekly")
        folder.rule = FolderRule(titleIs: "Weekly sync", provider: .googleMeet)
        folder.filesAutomatically = true
        try folders.write(folder)

        let backend = FakeAIBackend()
        backend.enrichment = MeetingEnrichment(summary: "Discussed the review.")
        let run = try await Self.processed(root: root, backend: backend, settings: AppSettings())

        guard let found = run.repository.findMeeting(id: run.metadata.id) else {
            Issue.record("the meeting went missing")
            return
        }
        #expect(found.metadata.folderName == "Weekly")
        #expect(found.store.layout.root.deletingLastPathComponent().lastPathComponent == "Weekly")
        #expect(found.store.readFolderSuggestion()?.reason == .rule)
        #expect(run.repository.meetings(inFolder: "Weekly").count == 1)
    }

    @Test("a folder with its switch off is offered, never taken")
    func aFolderWithItsSwitchOffIsOfferedNeverTaken() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = MeetingFolderStore(root: root)
        var folder = try folders.create(name: "Weekly")
        folder.rule = FolderRule(titleIs: "Weekly sync", provider: .googleMeet)
        try folders.write(folder)

        let backend = FakeAIBackend()
        let run = try await Self.processed(root: root, backend: backend, settings: AppSettings())

        guard let found = run.repository.findMeeting(id: run.metadata.id) else {
            Issue.record("the meeting went missing")
            return
        }
        #expect(found.metadata.folderName == nil, "nothing moved")
        #expect(found.store.readFolderSuggestion()?.folderName == "Weekly")
    }

    @Test("what a model answers is written down and never acted on")
    func whatAModelAnswersIsWrittenDownAndNeverActedOn() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = MeetingFolderStore(root: root)
        var folder = try folders.create(name: "Fenwick Trust", about: "Client work")
        // Switched on, to prove that a model's answer is refused even by
        // a folder that files everything it is allowed to.
        folder.filesAutomatically = true
        try folders.write(folder)

        let backend = FakeAIBackend()
        backend.enrichment = MeetingEnrichment(
            summary: "Discussed the review.",
            folderCandidates: [ModelFolderCandidate(
                folderName: "Fenwick Trust", confidence: 0.9,
                why: "their security review", quote: "The security review is still open.",
                atSeconds: 1
            )]
        )
        let run = try await Self.processed(root: root, backend: backend, settings: AppSettings())

        guard let found = run.repository.findMeeting(id: run.metadata.id) else {
            Issue.record("the meeting went missing")
            return
        }
        let suggestion = found.store.readFolderSuggestion()
        #expect(suggestion?.folderName == "Fenwick Trust")
        #expect(suggestion?.reason == .model)
        #expect(suggestion?.quote == "The security review is still open.")
        #expect(found.metadata.folderName == nil, "a model guess never files")
    }

    @Test("the folders are shown to the model, with what they are for")
    func theFoldersAreShownToTheModelWithWhatTheyAreFor() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = MeetingFolderStore(root: root)
        try folders.create(name: "Fenwick Trust", about: "Client work with Fenwick Trust")

        let backend = FakeAIBackend()
        _ = try await Self.processed(root: root, backend: backend, settings: AppSettings())

        #expect(backend.lastEnrichmentFolders?.count == 1)
        #expect(backend.lastEnrichmentFolders?.first?.name == "Fenwick Trust")
        #expect(backend.lastEnrichmentFolders?.first?.about == "Client work with Fenwick Trust")
    }

    @Test("recurring meetings only asks the model nothing about folders")
    func recurringMeetingsOnlyAsksTheModelNothingAboutFolders() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = MeetingFolderStore(root: root)
        try folders.create(name: "Fenwick Trust", about: "Client work")

        var settings = AppSettings()
        settings.enrichment.folderReach = .recurringOnly
        let backend = FakeAIBackend()
        backend.enrichment = MeetingEnrichment(
            summary: "Discussed the review.",
            folderCandidates: [ModelFolderCandidate(
                folderName: "Fenwick Trust", confidence: 0.99, why: "named throughout",
                quote: "Fenwick Trust", atSeconds: 1
            )]
        )
        let run = try await Self.processed(root: root, backend: backend, settings: settings)

        #expect(backend.lastEnrichmentFolders?.isEmpty == true, "no catalogue was sent")
        guard let found = run.repository.findMeeting(id: run.metadata.id) else {
            Issue.record("the meeting went missing")
            return
        }
        #expect(found.store.readFolderSuggestion() == nil, "an answer arriving anyway is still refused")
    }

}
