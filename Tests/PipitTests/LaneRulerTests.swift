import Testing

@testable import PipitUI

@Suite("LaneRuler")
struct LaneRulerTests {
    @Test("marks are the shortest round gap that keeps their labels apart")
    func picksTheShortestGapThatFits() {
        // A 40 minute meeting: 5 minutes is 64 points across 512, the first
        // round gap with room for a label.
        #expect(LaneRuler.interval(duration: 2_400, width: 512) == 300)
        // The same meeting across a full-screen bar fits a mark every 2 minutes.
        #expect(LaneRuler.interval(duration: 2_400, width: 1_400) == 120)
        // A 3 minute call needs no gap wider than 30 seconds.
        #expect(LaneRuler.interval(duration: 180, width: 600) == 30)
    }

    @Test("a long meeting in a narrow bar falls back to the widest gap")
    func longMeetingUsesWidestGap() {
        #expect(LaneRuler.interval(duration: 6 * 3_600, width: 200) == 7_200)
    }

    @Test("no marks without a length or a width")
    func emptyTimeline() {
        #expect(LaneRuler.interval(duration: 0, width: 500) == 0)
        #expect(LaneRuler.interval(duration: 600, width: 0) == 0)
    }
}
