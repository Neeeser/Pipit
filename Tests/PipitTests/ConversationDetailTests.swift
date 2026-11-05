import Foundation
import PipitCore
import PipitIntegrations
import PipitServices
import PipitUI
import Synchronization
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

    private final class Posted: @unchecked Sendable {
        private let lock = NSLock()
        private var categories: [NotificationService.Category] = []
        func add(_ category: NotificationService.Category) { lock.withLock { categories.append(category) } }
        var all: [NotificationService.Category] { lock.withLock { categories } }
    }

    @MainActor
    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
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
        let posted = Posted()
        runtime.notifications = NotificationService(observer: { category, _ in posted.add(category) })
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        model.show(meetingID: made[0].id)
        let detail = try #require(model.detail)
        detail.reload()
        #expect(!detail.summaryIsOutOfDate, "no mark yet")

        _ = try made[0].store.updateMetadata { $0.titles.ai = "Old title" }
        // Marked by a real merge; there is no key, so nothing is written.
        model.merge(model.rows)
        await model.reload()
        let merged = try #require(model.detail)
        await Self.waitUntil {
            merged.reload()
            return merged.metadata?.processing.skippedForMissingKey == true
        }
        #expect(merged.metadata?.summaryNeedsRewrite == true)
        #expect(merged.metadata?.processing.skippedForMissingKey == true, "the pane says why")
        #expect(!merged.summaryIsOutOfDate, "a meeting with no summary shows no notice")

        try made[0].store.writeSummary("First part only.")
        merged.reload()
        #expect(merged.summaryIsOutOfDate)

        backend.configured = true
        backend.enrichment = MeetingEnrichment(title: "New title", summary: "Both parts.")
        merged.rewriteSummary()
        await Self.waitUntil { !merged.isEnriching }

        #expect(merged.summary == "Both parts.")
        #expect(merged.metadata?.titles.ai == "New title", "the title is written again too")
        #expect(!merged.summaryIsOutOfDate)
        #expect(posted.all.isEmpty, "no ready notification and no problem notice")
    }

    @Test("the button waits while a rewrite runs, and a failed one is reported without Retry")
    @MainActor
    func buttonWaitsAndFailureHasNoRetry() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try (0..<2).map { index in
            try RuntimeFixtures.makeMeeting(
                root: root, clusters: ["remote-001_speaker_00"], title: "Part \(index)",
                startedAt: Self.base.addingTimeInterval(Double(index) * 3_600))
        }
        let backend = FakeAIBackend()
        let runtime = RuntimeFixtures.makeRuntime(root: root, backend: backend)
        let posted = Posted()
        runtime.notifications = NotificationService(observer: { category, _ in posted.add(category) })
        runtime.combine(
            meetingID: made[1].id, into: made[0].id, reason: "a test", rewritingSummary: false)
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        model.show(meetingID: made[0].id)
        let detail = try #require(model.detail)
        let open = Mutex(false)
        backend.enrichInterference = {
            while !open.withLock({ $0 }) { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        backend.failEnrichment = .transport(reason: "offline")

        runtime.refreshConversationSummary(meetingID: made[0].id)
        await Self.waitUntil { detail.isSummaryBeingWritten }
        #expect(detail.isSummaryBeingWritten, "a rewrite from anywhere holds the button")
        open.withLock { $0 = true }
        await Self.waitUntil { !detail.isSummaryBeingWritten }
        await Self.waitUntil { !posted.all.isEmpty }

        #expect(posted.all == [.summaryProblem], "reported, and not as a processing problem with Retry")
    }

    @Test("separating a part while the model is out of reach posts one notification")
    @MainActor
    func separateOfflinePostsOnce() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try (0..<2).map { index in
            try RuntimeFixtures.makeMeeting(
                root: root, clusters: ["remote-001_speaker_00"], title: "Part \(index)",
                startedAt: Self.base.addingTimeInterval(Double(index) * 3_600))
        }
        let backend = FakeAIBackend()
        let runtime = RuntimeFixtures.makeRuntime(root: root, backend: backend)
        let posted = Posted()
        runtime.notifications = NotificationService(observer: { category, _ in posted.add(category) })
        runtime.combine(
            meetingID: made[1].id, into: made[0].id, reason: "a test", rewritingSummary: false)
        backend.failEnrichment = .transport(reason: "offline")

        runtime.detachContinuation(meetingID: made[1].id)
        await Self.waitUntil { backend.enrichmentRequests.count >= 2 }
        await Self.waitUntil { runtime.summariesBeingWritten.isEmpty }

        #expect(posted.all == [.summaryProblem])
    }

    @Test("merging meetings that cannot be linked says so")
    @MainActor
    func mergeThatLinksNothingSaysSo() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try (0..<3).map { index in
            try RuntimeFixtures.makeMeeting(
                root: root, clusters: ["remote-001_speaker_00"], title: "Part \(index)",
                startedAt: Self.base.addingTimeInterval(Double(index) * 3_600))
        }
        let runtime = RuntimeFixtures.makeRuntime(root: root)
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        let rows = model.rows
        // The folders of the later two disappear after the list was read.
        for part in made.dropFirst() {
            try FileManager.default.removeItem(at: part.store.layout.root)
        }

        model.merge(rows)

        #expect(model.receipt?.text == "These meetings could not be merged.")
    }

    @Test("a different failure and the person's own click still post after a repeat was left out")
    @MainActor
    func throttleLeavesOutOnlyARepeat() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try (0..<2).map { index in
            try RuntimeFixtures.makeMeeting(
                root: root, clusters: ["remote-001_speaker_00"], title: "Part \(index)",
                startedAt: Self.base.addingTimeInterval(Double(index) * 3_600))
        }
        let backend = FakeAIBackend()
        let runtime = RuntimeFixtures.makeRuntime(root: root, backend: backend)
        let posted = Posted()
        runtime.notifications = NotificationService(observer: { category, _ in posted.add(category) })
        runtime.combine(
            meetingID: made[1].id, into: made[0].id, reason: "a test", rewritingSummary: false)
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        model.show(meetingID: made[0].id)
        let detail = try #require(model.detail)

        func ask(_ requests: Int, click: Bool = false) async {
            if click {
                detail.rewriteSummary()
            } else {
                runtime.refreshConversationSummary(meetingID: made[0].id)
            }
            await Self.waitUntil { backend.enrichmentRequests.count >= requests }
            await Self.waitUntil { runtime.summariesBeingWritten.isEmpty && !detail.isEnriching }
        }

        backend.failEnrichment = .transport(reason: "offline")
        await ask(1)
        #expect(posted.all.count == 1)
        await ask(2)
        #expect(posted.all.count == 1, "the same failure again is left out")
        backend.failEnrichment = .authenticationFailed
        await ask(3)
        #expect(posted.all.count == 2, "a different failure posts")
        backend.failEnrichment = .authenticationFailed
        await ask(4, click: true)
        #expect(posted.all.count == 3, "the person's own click posts even for a repeat")
    }
}
