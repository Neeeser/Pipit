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
}
