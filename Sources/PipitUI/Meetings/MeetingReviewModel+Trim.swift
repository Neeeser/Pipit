import Foundation
import PipitCore
import PipitServices

/// Trim, from the meeting pane: which stretch may be kept, and the cut itself.
extension MeetingReviewModel {
    /// Whether the meeting can be trimmed now: every recording in it has
    /// finished processing, has its audio saved as one file per track, and
    /// was recorded in one piece. An imported meeting keeps its original file
    /// whole, so it cannot be cut.
    public var canTrim: Bool {
        guard !isTrimming, !isRedoingMicrophone, playback.hasAudio, !recordings.isEmpty else { return false }
        return recordings.allSatisfy { metadata in
            metadata.source != .imported && metadata.audioArchive != nil && metadata.runs.count <= 1
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

    /// The cut for each recording that a trim from `start` to `end` on the
    /// playback timeline changes. Playback seconds within a part are seconds
    /// on that recording's own timeline, which is what Trim measures in. Only
    /// the start of the first part and the end of the last part move, so a
    /// middle recording is never cut and a whole one is never removed.
    static func cuts(
        parts: [PlaybackTimeline.Part], durations: [String: Double], keepFrom start: Double, to end: Double
    ) -> [(id: String, range: TrimRange)] {
        guard let first = parts.first, let last = parts.last else { return [] }
        let keepStart = min(max(start, first.start), first.end)
        let keepEnd = min(max(end, last.start), last.end)
        // The handle sits at the end of the timeline, which can be later than
        // the recording's recorded length where one track began late.
        let toEnd = keepEnd >= last.end - MeetingTrim.tolerance
        let firstDuration = durations[first.recordingID] ?? first.duration
        let lastDuration = durations[last.recordingID] ?? last.duration
        var cuts: [(id: String, range: TrimRange)] = []
        if first.recordingID == last.recordingID {
            if let range = TrimRange(
                start: keepStart - first.start, end: keepEnd - first.start, duration: firstDuration, toEnd: toEnd)
            {
                cuts.append((first.recordingID, range))
            }
            return cuts
        }
        if let range = TrimRange(
            start: keepStart - first.start, end: firstDuration, duration: firstDuration, toEnd: true)
        {
            cuts.append((first.recordingID, range))
        }
        if let range = TrimRange(start: 0, end: keepEnd - last.start, duration: lastDuration, toEnd: toEnd) {
            cuts.append((last.recordingID, range))
        }
        return cuts
    }

    /// Cuts the meeting to the stretch from `start` to `end` on the playback
    /// timeline and deletes the rest. The view has already asked the person
    /// to confirm.
    public func trim(keepFrom start: Double, to end: Double) {
        guard canTrim else { return }
        let durations = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0.durationSeconds) })
        let cuts = Self.cuts(parts: playback.timeline.parts, durations: durations, keepFrom: start, to: end)
        guard !cuts.isEmpty else { return }
        // The player holds the file that is about to be replaced.
        playback.stop()
        isTrimming = true
        trimMessage = nil
        var remaining = cuts.count
        var outcome = ProcessingPipeline.TrimOutcome()
        for cut in cuts {
            runtime.trimMeeting(meetingID: cut.id, to: cut.range) { [weak self] result in
                guard let self else { return }
                outcome.failure = outcome.failure ?? result.failure
                outcome.transcriptNotRebuilt = outcome.transcriptNotRebuilt || result.transcriptNotRebuilt
                remaining -= 1
                guard remaining == 0 else { return }
                isTrimming = false
                trimMessage = Self.trimMessage(for: outcome)
                reload()
            }
        }
    }

    static func trimMessage(for outcome: ProcessingPipeline.TrimOutcome) -> String? {
        if let failure = outcome.failure { return trimMessage(for: failure) }
        if outcome.transcriptNotRebuilt { return "Trimmed. Choose Rebuild transcript to update the transcript." }
        return nil
    }

    static func trimMessage(for error: TrimError) -> String {
        switch error {
        case .notFinished: "Wait for this meeting to finish processing, then trim it."
        case .notArchived, .severalRuns: "This meeting can't be trimmed."
        case .imported: "A meeting imported from a file can't be trimmed."
        case .invalidRange: "Keep at least a second of the meeting."
        case .interrupted: "An earlier trim was finished. Check the meeting, then trim again."
        case .verificationFailed, .filesNotWritten: "Couldn't trim this meeting. Try again."
        }
    }
}
