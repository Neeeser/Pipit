import PipitServices
import Testing

@testable import PipitUI

@Suite("SpeakerOrder")
struct SpeakerOrderTests {
    private func row(_ cluster: String, seconds: Double) -> MeetingSpeakerRow {
        MeetingSpeakerRow(
            clusterID: cluster, recordingID: "rec-a", displayName: cluster, isUnnamed: true,
            band: .unknown, origin: .ai, identity: nil, speechSeconds: seconds,
            provenance: nil, meetingCount: 0
        )
    }

    @Test("speakers are listed by talk time, ties in the order they first spoke")
    @MainActor
    func sortsByTalkTime() {
        let firstSpoke = [
            row("greeter", seconds: 3), row("host", seconds: 720), row("guest", seconds: 60),
            row("lateA", seconds: 15), row("lateB", seconds: 15),
        ]
        let ordered = MeetingReviewModel.byTalkTime(firstSpoke).map(\.clusterID)
        #expect(ordered == ["host", "guest", "lateA", "lateB", "greeter"])
    }
}
