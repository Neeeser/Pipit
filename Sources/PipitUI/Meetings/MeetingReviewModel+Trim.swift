import Foundation
import PipitCore
import PipitServices

/// Trim, from the meeting pane: which stretch may be kept, and the cut itself.
extension MeetingReviewModel {
    /// Whether the meeting can be trimmed now: every recording in it has
    /// finished processing, has its audio saved as one file per track, and
    /// was recorded in one piece.
    public var canTrim: Bool {
        guard !isTrimming, !isRedoingMicrophone, playback.hasAudio, !recordings.isEmpty else { return false }
        return recordings.allSatisfy { metadata in
            metadata.audioArchive != nil && metadata.runs.count <= 1
                && metadata.processing.state == .complete && metadata.microphoneRedoRequestedAt == nil
        }
    }

    /// Where the trim handles may go, on the playback timeline: the start
    /// within the first recording and the end within the last, so a merged
    /// meeting is trimmed at its outer ends and never loses a whole part.
    public var trimLimits: (start: ClosedRange<Double>, end: ClosedRange<Double>)? {
        let parts = playback.timeline.parts
        guard let first = parts.first, let last = parts.last else { return nil }
        return (first.start...first.end, last.start...last.end)
    }

    /// Cuts the meeting to the stretch from `start` to `end` on the playback
    /// timeline and deletes the rest. The view has already asked the person
    /// to confirm.
    public func trim(keepFrom start: Double, to end: Double) {
        guard canTrim, let limits = trimLimits else { return }
        let parts = playback.timeline.parts
        guard let first = parts.first, let last = parts.last else { return }
        let keepStart = min(max(start, limits.start.lowerBound), limits.start.upperBound)
        let keepEnd = min(max(end, limits.end.lowerBound), limits.end.upperBound)

        // Playback seconds within a part are seconds on that recording's own
        // timeline, which is what Trim measures in.
        var cuts: [(id: String, range: TrimRange)] = []
        let firstDuration = recordings.first { $0.id == first.recordingID }?.durationSeconds ?? first.duration
        let lastDuration = recordings.first { $0.id == last.recordingID }?.durationSeconds ?? last.duration
        if first.recordingID == last.recordingID {
            if let range = TrimRange(
                start: keepStart - first.start, end: keepEnd - first.start, duration: firstDuration)
            {
                cuts.append((first.recordingID, range))
            }
        } else {
            if let range = TrimRange(start: keepStart - first.start, end: firstDuration, duration: firstDuration) {
                cuts.append((first.recordingID, range))
            }
            if let range = TrimRange(start: 0, end: keepEnd - last.start, duration: lastDuration) {
                cuts.append((last.recordingID, range))
            }
        }
        guard !cuts.isEmpty else { return }
        // The player holds the file that is about to be replaced.
        playback.stop()
        isTrimming = true
        trimMessage = nil
        var remaining = cuts.count
        var refusal: TrimError?
        for cut in cuts {
            runtime.trimMeeting(meetingID: cut.id, to: cut.range) { [weak self] failure in
                guard let self else { return }
                if let failure { refusal = failure }
                remaining -= 1
                guard remaining == 0 else { return }
                isTrimming = false
                trimMessage = refusal.map(Self.trimMessage(for:))
                reload()
            }
        }
    }

    static func trimMessage(for error: TrimError) -> String {
        switch error {
        case .notFinished: "Wait for this meeting to finish processing, then trim it."
        case .notArchived, .severalRuns: "This meeting can't be trimmed."
        case .invalidRange: "Keep at least a second of the meeting."
        case .verificationFailed, .filesNotWritten: "Couldn't trim this meeting. Try again."
        }
    }
}
