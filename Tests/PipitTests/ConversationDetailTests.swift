import Foundation
import PipitCore
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

        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        model.show(meetingID: made[0].id)
        let detail = try #require(model.detail)
        detail.reload()

        #expect(detail.continuationNotes == [MeetingNoteEntry(text: "later note", at: 3_720)])
        #expect(detail.summaryIsOutOfDate)
        #expect(detail.notes.isEmpty, "the Notes tab still edits only the first recording's file")
    }
}
