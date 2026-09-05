import Foundation
import PipitCore

/// Provider evidence and accessibility readings, built by hand.
public enum DetectionFixtures {
    public static func meetEvidence(
        confidence: MeetingConfidence, source: EvidenceSource = .browserSensor,
        meetingID: String? = "abc-defg-hij"
    ) -> ProviderEvidence {
        ProviderEvidence(
            provider: .googleMeet, confidence: confidence, source: source,
            meetingID: meetingID, url: meetingID.map { "https://meet.google.com/\($0)" },
            title: nil, browser: .firefox, applicationBundleID: "org.mozilla.firefox",
            audioBundlePrefixes: ["org.mozilla.firefox"]
        )
    }

    public static func joined(mute: Bool? = nil, title: String? = nil) -> SlackAccessibilityObservation {
        SlackAccessibilityObservation(
            hasLeaveHuddleControl: true, subtreeWasEmpty: false, isMuted: mute, windowTitle: title
        )
    }
}
