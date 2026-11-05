import Foundation
import PipitCore
import PipitIntegrations
import PipitServices
import PipitUI
import Testing

/// What the summary tab reads from a conversation made of several recordings.
@Suite("ConversationDetail")
struct ConversationDetailTests {
    private static let base = Date(timeIntervalSince1970: 1_787_070_000)

    @Test("notes from a later recording are on the summary timeline, and an outdated summary is flagged")
    @MainActor
    func laterNotesAndOutdatedFlag() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try (0..<2).map { index in
            try RuntimeFixtures.makeMeeting(
                root: root, clusters: ["remote-001_speaker_00"], title: "Part \(index)",
                startedAt: Self.base.addingTimeInterval(Double(index) * 3_600))
        }
        let runtime = RuntimeFixtures.makeRuntime(root: root)
        runtime.combine(
            meetingID: made[1].id, into: made[0].id, reason: "a test", rewritingSummary: false)
        try made[1].store.appendNote("later note", at: Self.base.addingTimeInterval(3_720))
        _ = try made[0].store.updateMetadata { $0.summaryNeedsRewrite = true }
        try made[0].store.writeSummary("First part only.")

        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        model.show(meetingID: made[0].id)
        let detail = try #require(model.detail)
        detail.reload()

        #expect(detail.continuationNotes == [MeetingNoteEntry(text: "later note", at: 3_720)])
        #expect(detail.summaryIsOutOfDate)
        #expect(detail.notes.isEmpty, "the Notes tab still edits only the first recording's file")
    }

    @Test("a merge with no key leaves the summary marked, and Write again rewrites it with no notification")
    @MainActor
    func outdatedNoticeAndWriteAgain() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try (0..<2).map { index in
            try RuntimeFixtures.makeMeeting(
                root: root, clusters: ["remote-001_speaker_00"], title: "Part \(index)",
                startedAt: Self.base.addingTimeInterval(Double(index) * 3_600))
        }
        let backend = FakeAIBackend()
        backend.configured = false
        let runtime = RuntimeFixtures.makeRuntime(root: root, backend: backend)
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        model.show(meetingID: made[0].id)
        let detail = try #require(model.detail)
        detail.reload()
        try await Task.sleep(nanoseconds: 1)
        #expect(!detail.summaryIsOutOfDate, "no mark yet")

        _ = try made[0].store.updateMetadata { $0.titles.ai = "Old title" }
        // Marked by a real merge; there is no key, so nothing is written.
        model.merge(model.rows)
        await model.reload()
        let merged = try #require(model.detail)
        merged.reload()
        #expect(merged.metadata?.summaryNeedsRewrite == true)
        #expect(!merged.summaryIsOutOfDate, "a meeting with no summary shows no notice")

        try made[0].store.writeSummary("First part only.")
        merged.reload()
        #expect(merged.summaryIsOutOfDate)

        backend.configured = true
        backend.enrichment = MeetingEnrichment(title: "New title", summary: "Both parts.")
        merged.rewriteSummary()
        let deadline = Date().addingTimeInterval(10)
        while merged.isEnriching, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }

        #expect(merged.summary == "Both parts.")
        #expect(merged.metadata?.titles.ai == "New title", "the title is written again too")
        #expect(!merged.summaryIsOutOfDate)
    }
}
