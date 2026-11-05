import PipitCore
import PipitServices

extension MeetingReviewModel {
    /// Whether a summary written before the parts changed can be written again
    /// now: a model is wanted and no part is still processing.
    public var summaryIsOutOfDate: Bool {
        guard metadata?.summaryNeedsRewrite == true, runtime.settings.enrichment.wantsAnything,
            recordings.allSatisfy({
                $0.processing.state == .complete || $0.processing.state == .failed
            })
        else { return false }
        return !(summary?.isEmpty ?? true) || !(generatedSummary?.isEmpty ?? true)
    }

    /// Whether a rewrite of this meeting's summary is running, started by
    /// anything, so the button does not ask for a second one.
    public var isSummaryBeingWritten: Bool { runtime.summariesBeingWritten.contains(meetingID) }

    /// Writes summary, title and description again from every part.
    public func rewriteSummary() {
        guard !isEnriching else { return }
        isEnriching = true
        runtime.refreshConversationSummary(meetingID: meetingID) { [weak self] in
            self?.isEnriching = false
            self?.reload()
        }
    }
}
