import Foundation
import PipitCore
import Testing

@testable import PipitEval

/// Which of a model's items `pipit-eval summaries` compares with which part of
/// the answer key.
@Suite("Summary scoring")
struct SummaryScoringTests {
    private static func truth(actionItems: [String]) -> SummaryTruth {
        SummaryTruth(
            meeting: "synthetic", overview: "",
            actionItems: actionItems.map {
                SummaryTruth.ActionItem(task: $0, owner: "", due: "", at: "01:00", quote: "", mustFind: true)
            },
            decisions: [], openQuestions: [], topics: [])
    }

    /// The prompt asks for a question someone has to go and answer as an
    /// action item, written as the task of finding out, so the key's action
    /// items are what it is compared with.
    @Test("a task flagged as a question is compared with the key's action items")
    func questionTaskIsComparedWithActionItems() {
        let summary = GeneratedSummary(topics: [
            .init(
                title: "Costs",
                actionItems: [
                    .init(task: "Find out what the battery costs", isQuestion: true),
                    .init(task: "Send the slides"),
                ])
        ])
        let lists = SummaryEvalCommand.Lists(
            summary: summary, truth: Self.truth(actionItems: ["Ask what the battery costs", "Send the slides"]))

        #expect(lists.kinds.map(\.name) == ["action item"])
        #expect(lists.kinds[0].model.map(\.text) == ["Find out what the battery costs", "Send the slides"])
        #expect(lists.items.count == 2)
    }
}
