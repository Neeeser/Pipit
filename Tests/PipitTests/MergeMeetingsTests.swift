import Foundation
import PipitCore
import PipitServices
import PipitUI
import Testing

/// Merging several selected meetings into one conversation.
@Suite("MergeMeetings")
struct MergeMeetingsTests {
    private static let base = Date(timeIntervalSince1970: 1_787_070_000)

    private static func candidate(
        _ id: String, minute: Double, state: ProcessingState = .complete
    ) -> MeetingMergePlan.Candidate {
        .init(id: id, startedAt: base.addingTimeInterval(minute * 60), state: state)
    }

    @Test("the earliest meeting is the primary and the rest are combined in order")
    func earliestIsPrimary() {
        let plan = MeetingMergePlan([
            Self.candidate("c", minute: 30), Self.candidate("a", minute: 0),
            Self.candidate("b", minute: 10),
        ])
        #expect(plan.primaryID == "a")
        #expect(plan.combineIDs == ["b", "c"])
        #expect(plan.skippedIDs.isEmpty)
    }

    @Test("a meeting still being recorded is skipped, and the earliest of the rest leads")
    func recordingIsSkipped() {
        let plan = MeetingMergePlan([
            Self.candidate("a", minute: 0, state: .recording),
            Self.candidate("b", minute: 10, state: .finalizing),
            Self.candidate("c", minute: 20), Self.candidate("d", minute: 30, state: .transcribing),
        ])
        #expect(plan.primaryID == "c")
        #expect(plan.combineIDs == ["d"])
        #expect(plan.skippedIDs == ["a", "b"])
    }

    @Test("fewer than two eligible meetings is not a merge")
    func needsTwo() {
        let plan = MeetingMergePlan([
            Self.candidate("a", minute: 0), Self.candidate("b", minute: 5, state: .recording),
        ])
        #expect(!plan.canMerge)
        #expect(plan.combineIDs.isEmpty)
        #expect(plan.skippedIDs == ["b"])
        #expect(!MeetingMergePlan([]).canMerge)
    }

    @Test("a repeated identifier counts once")
    func duplicates() {
        let plan = MeetingMergePlan([Self.candidate("a", minute: 0), Self.candidate("a", minute: 0)])
        #expect(!plan.canMerge)
    }

    private static func makeThree(root: URL) throws -> [String] {
        try (0..<3).map { index in
            try RuntimeFixtures.makeMeeting(
                root: root, clusters: ["remote-001_speaker_00"], title: "Part \(index)",
                startedAt: base.addingTimeInterval(Double(index) * 3_600)
            ).id
        }
    }

    @Test("merging links every later meeting to the earliest and leaves one row")
    @MainActor
    func mergeLinksAndSelects() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = try Self.makeThree(root: root)
        let runtime = RuntimeFixtures.makeRuntime(root: root)
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        #expect(model.rows.count == 3)

        // Shift-click selects the range between the anchor and the clicked row.
        let visible = model.sections.flatMap(\.rows).map(\.id)
        model.select(visible[0], extending: false)
        model.select(visible[2], extending: false, throughRange: true)
        #expect(model.selection == Set(ids))

        model.merge(model.selectedRows)
        await model.reload()

        #expect(model.rows.map(\.id) == [ids[0]])
        #expect(model.selection == [ids[0]])
        #expect(model.detail?.meetingID == ids[0])
        let logical = try #require(runtime.repository.logicalMeeting(id: ids[0]))
        #expect(logical.recordings.map(\.metadata.id) == ids)
    }

    @Test("Shift-click measures from the meeting that was shown, and Command-Shift adds a range")
    @MainActor
    func shiftClickAnchor() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = try Self.makeThree(root: root)
        let runtime = RuntimeFixtures.makeRuntime(root: root)
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        let visible = model.sections.flatMap(\.rows).map(\.id)

        // Opened from a notification, not clicked.
        model.show(meetingID: visible[0])
        model.select(visible[2], extending: false, throughRange: true)
        #expect(model.selection == Set(ids))

        model.select(visible[0], extending: false)
        model.select(visible[2], extending: true)
        #expect(model.selection == [visible[0], visible[2]])
        model.select(visible[1], extending: true, throughRange: true)
        #expect(model.selection == Set(ids), "the range joins what was already selected")
    }

    @Test("a merged conversation merges whole and never forms a chain")
    @MainActor
    func existingConversationJoinsWhole() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = try Self.makeThree(root: root)
        let runtime = RuntimeFixtures.makeRuntime(root: root)
        // The later two are already one conversation led by the middle one.
        runtime.combine(meetingID: ids[2], into: ids[1], reason: "a test")
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        #expect(model.rows.map(\.id).sorted() == [ids[0], ids[1]].sorted())

        model.merge(model.rows)

        let first = try #require(runtime.repository.findMeeting(id: ids[0]))
        #expect(first.metadata.absorbedMeetingIDs.sorted() == [ids[1], ids[2]].sorted())
        for id in [ids[1], ids[2]] {
            let found = try #require(runtime.repository.findMeeting(id: id, includingMerged: true))
            #expect(found.metadata.mergedIntoMeetingID == ids[0], "linked straight to the primary")
        }
        let middle = try #require(runtime.repository.findMeeting(id: ids[1], includingMerged: true))
        #expect(middle.metadata.absorbedMeetingIDs.isEmpty)

        // Undo works for a part merged this way, and leaves the other linked.
        runtime.detachContinuation(meetingID: ids[2])
        let logical = try #require(runtime.repository.logicalMeeting(id: ids[0]))
        #expect(logical.recordings.map(\.metadata.id) == [ids[0], ids[1]])
        #expect(runtime.repository.findMeeting(id: ids[2]) != nil)
    }

    // MARK: - the summary reads the whole conversation

    /// Two finished recordings an hour apart, each saying something only it
    /// says, in a runtime whose model is a fake that keeps what it was asked.
    @MainActor
    private static func makeSummarizedPair(
        root: URL, backend: FakeAIBackend
    ) throws -> (runtime: PipitRuntime, ids: [String]) {
        let words = ["opening budget question", "closing hiring answer"]
        let ids = try words.enumerated().map { index, text in
            try RuntimeFixtures.makeMeeting(
                root: root, clusters: ["remote-001_speaker_00"], words: text,
                title: "Part \(index)",
                startedAt: base.addingTimeInterval(Double(index) * 3_600)
            ).id
        }
        return (RuntimeFixtures.makeRuntime(root: root, backend: backend), ids)
    }

    /// Waits for the background job a link starts, which no call returns.
    @MainActor
    private static func waitForRequests(_ count: Int, on backend: FakeAIBackend) async {
        await waitUntil { backend.enrichmentRequests.count >= count }
    }

    @MainActor
    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Lets the test hold the model's answer until it says so, so everything
    /// else a merge started has run while the first request is still open.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        func release() { lock.withLock { open = true } }
        func wait() async {
            while !lock.withLock({ open }) { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
    }

    /// The request is the first thing to happen; the write and the state that
    /// follow it come a moment later.
    @MainActor
    private static func waitForComplete(_ id: String, in runtime: PipitRuntime) async {
        let deadline = Date().addingTimeInterval(10)
        while runtime.repository.findMeeting(id: id)?.metadata.processing.state != .complete,
            Date() < deadline
        {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test("merging two processed meetings summarizes both, on the conversation's timeline")
    @MainActor
    func mergeWritesTheSummaryFromEveryRecording() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeAIBackend()
        let (runtime, ids) = try Self.makeSummarizedPair(root: root, backend: backend)
        _ = try runtime.repository.findMeeting(id: ids[0])?.store.updateMetadata {
            $0.titles.human = "Named by a person"
        }

        runtime.combine(meetingID: ids[1], into: ids[0], reason: "a test")
        await Self.waitForRequests(1, on: backend)

        let request = try #require(backend.enrichmentRequests.last)
        #expect(request.transcript.contains("opening budget question"))
        #expect(request.transcript.contains("closing hiring answer"))
        // The second recording started an hour in, so its first line sits there.
        #expect(request.transcript.contains("[1:00:00]"))
        #expect(request.durationSeconds >= 3_600 + 600, "the timeline reaches the end of the last part")

        // The primary is written again and finished, and a person's title wins.
        await Self.waitForComplete(ids[0], in: runtime)
        let primary = try #require(runtime.repository.findMeeting(id: ids[0]))
        #expect(primary.store.readSummaryDocument().summary == "Discussed retrieval.")
        let metadata = try primary.store.readMetadata()
        #expect(metadata.processing.state == .complete)
        #expect(metadata.displayTitle == "Named by a person")
        // The continuation does not write a summary of its own.
        let later = try #require(runtime.repository.findMeeting(id: ids[1], includingMerged: true))
        #expect((later.store.readSummaryDocument().summary ?? "").isEmpty)
    }

    @Test("merging several meetings at once writes the summary once")
    @MainActor
    func mergeOfThreeWritesOneSummary() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeAIBackend()
        let runtime = RuntimeFixtures.makeRuntime(root: root, backend: backend)
        let ids = try Self.makeThree(root: root)
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()

        let gate = Gate()
        backend.enrichInterference = { await gate.wait() }
        model.merge(model.rows)
        // The first request is open. Anything else the merge asked for has run
        // by the time the test gets the main actor back, and a second ask would
        // have added a debt that a second request pays once this one ends.
        await Self.waitForRequests(1, on: backend)
        for _ in 0..<50 { await Task.yield() }
        gate.release()
        await Self.waitForComplete(ids[0], in: runtime)
        await Self.waitUntil { runtime.repository.findMeeting(id: ids[0])?.store.readSummaryDocument().summary != nil }
        for _ in 0..<200 { await Task.yield() }

        #expect(backend.enrichmentRequests.count == 1)
        #expect(runtime.repository.logicalMeeting(id: ids[0])?.recordings.count == 3)
    }

    @Test("separating a part writes the summary again for what is left")
    @MainActor
    func separatingAPartRewritesThePrimary() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeAIBackend()
        let (runtime, ids) = try Self.makeSummarizedPair(root: root, backend: backend)
        runtime.combine(meetingID: ids[1], into: ids[0], reason: "a test", rewritingSummary: false)

        runtime.detachContinuation(meetingID: ids[1])
        await Self.waitForRequests(2, on: backend)

        // One for each half, now that each is a meeting of its own.
        let texts = backend.enrichmentRequests.map(\.transcript)
        let first = try #require(texts.first { $0.contains("opening budget question") })
        #expect(!first.contains("closing hiring answer"), "the separated part is left out")
        #expect(texts.contains { $0.contains("closing hiring answer") && !$0.contains("opening") })
    }
}
