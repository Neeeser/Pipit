import PipitCore
import PipitServices
import SwiftUI

extension MeetingReviewModel {
    /// When the current processing step started, for the progress bar.
    var processingClock: ProcessingStepClock.Running? { runtime.stepClock.running[meetingID] }

    /// How long each step has taken on this Mac.
    var processingTimes: ProcessingTimeHistory { runtime.processingTimes }

    /// The time on the clock the processing steps are timed with.
    var processingNow: Date { runtime.now }
}

/// Where a meeting's processing stands, built from the stage on disk and the
/// live progress report.
struct ProcessingSteps: Equatable {
    /// The steps this meeting goes through, in order.
    var steps: [ProcessingStep]
    var current: ProcessingStep
    /// A line under the headline for something the step name does not say:
    /// waiting, or a model loading before the step can report progress.
    var note: String?
    var isWaiting: Bool
    /// The current step's own progress, where it reports any.
    var reported: Double?
    var meetingSeconds: Double

    /// The lines worth showing under the headline. Others name plumbing, such
    /// as aligning timings, that the step name already covers.
    private static let notes: Set<String> = [
        ProcessingPipeline.Progress.waitingForRecording,
        ProcessingPipeline.Progress.waitingForOtherMeeting,
        ProcessingPipeline.Progress.loadingSpeakerModel,
        ProcessingPipeline.Progress.preparingModels,
    ]

    /// Nil for a meeting that is recording, failed, or finished, which the
    /// pane shows its own way.
    ///
    /// - Parameter reached: the furthest the step's own progress has got, so
    ///   the bar never moves back when a later pass reports from zero.
    init?(
        state: ProcessingState, progress: ProcessingPipeline.Progress?, metadata: MeetingMetadata?,
        reached: Double? = nil
    ) {
        let live = progress?.state == state ? progress : nil
        guard let current = live?.step ?? ProcessingStep(state: state) else { return nil }
        var steps = metadata.map { ProcessingStep.steps(for: $0.source) } ?? ProcessingStep.allCases
        if !steps.contains(current) {
            steps.append(current)
            steps.sort()
        }
        self.steps = steps
        self.current = current
        let detail = live?.detail
        note = detail.flatMap { Self.notes.contains($0) ? $0 : nil }
        isWaiting = live?.isWaiting ?? false
        let liveFraction = live.flatMap { live -> Double? in
            if let fraction = live.fraction { return fraction }
            guard live.totalChunks > 0 else { return nil }
            return Double(live.completedChunks) / Double(live.totalChunks)
        }
        reported = [reached, liveFraction].compactMap { $0 }.max()
        meetingSeconds = metadata?.durationSeconds ?? 0
    }

    func estimate(secondsInStep: Double, history: ProcessingTimeHistory) -> ProcessingEstimate {
        ProcessingEstimate(
            steps: steps, current: current, secondsInStep: secondsInStep, reported: reported,
            history: history, meetingSeconds: meetingSeconds)
    }

    /// The time left in words, or nil while waiting or before this Mac has
    /// timed enough meetings for the number to mean anything.
    static func timeLeft(_ seconds: Double, history: ProcessingTimeHistory, isWaiting: Bool) -> String? {
        guard history.showsTimeLeft, !isWaiting else { return nil }
        if seconds < 60 { return "Less than a minute left" }
        return "About \(Int((seconds / 60).rounded(.up))) min left"
    }
}

/// What the transcript pane shows while a meeting is processed: the step now
/// running, one bar for the whole run split into a segment per step, and the
/// steps in order.
///
/// The bar fills from each step's own progress where it reports any, and from
/// this Mac's past step times where it does not, so it keeps moving through a
/// step that reports nothing.
struct ProcessingStepsView: View {
    let steps: ProcessingSteps
    /// When the current step started, waiting left out. Nil before the first
    /// report of this run arrives.
    let clock: ProcessingStepClock.Running?
    let history: ProcessingTimeHistory
    /// The time on the clock the step was timed with. The timeline below only
    /// says when to redraw.
    let now: () -> Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let seconds = clock?.secondsInStep(at: now()) ?? 0
            content(estimate: steps.estimate(secondsInStep: seconds, history: history))
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private func content(estimate: ProcessingEstimate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                // Still while waiting, since nothing is being worked on.
                if steps.isWaiting {
                    Image(systemName: "hourglass")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(steps.current.name)
                    .font(.title2.weight(.semibold))
                Spacer(minLength: 12)
                if let left = ProcessingSteps.timeLeft(
                    estimate.secondsLeft, history: history, isWaiting: steps.isWaiting)
                {
                    Text(left)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            // Kept in place when empty, so the bar does not jump when a note
            // comes and goes.
            Text(steps.note ?? " ")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 26)
                .padding(.top, 2)
                .accessibilityHidden(steps.note == nil)

            SegmentedBar(segments: estimate.segments, animates: !reduceMotion)
                .padding(.top, 14)
                .accessibilityElement()
                .accessibilityLabel("Processing")
                .accessibilityValue("\(Int((estimate.overall * 100).rounded())) percent, \(steps.current.name)")

            VStack(alignment: .leading, spacing: 0) {
                ForEach(steps.steps, id: \.self) { step in
                    row(step)
                }
            }
            .padding(.top, 24)
        }
    }

    private func row(_ step: ProcessingStep) -> some View {
        let isDone = step < steps.current
        let isNow = step == steps.current
        return HStack(spacing: 12) {
            marker(isDone: isDone, isNow: isNow)
                .frame(width: 18, height: 18)
            Text(step.name)
                .font(.body.weight(isNow ? .semibold : .regular))
                .foregroundStyle(isDone || isNow ? .primary : .secondary)
        }
        .frame(height: 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(step.name), \(isDone ? "done" : isNow ? "in progress" : "next")")
    }

    @ViewBuilder private func marker(isDone: Bool, isNow: Bool) -> some View {
        if isDone {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        } else if isNow {
            ZStack {
                Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                Circle().fill(Color.accentColor).padding(4)
            }
            .frame(width: 15, height: 15)
        } else {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
                .frame(width: 15, height: 15)
        }
    }
}

/// One bar for the whole run: a segment per step, each as wide as the step is
/// expected to take, filled as far as the step has got.
private struct SegmentedBar: View {
    let segments: [ProcessingEstimate.Segment]
    let animates: Bool

    private static let gap: CGFloat = 3
    private static let height: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let gaps = Self.gap * CGFloat(max(segments.count - 1, 0))
            let room = max(geometry.size.width - gaps, 0)
            HStack(spacing: Self.gap) {
                ForEach(segments, id: \.step) { segment in
                    let width = max(room * segment.share, 6)
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous).fill(Color.secondary.opacity(0.18))
                        Capsule(style: .continuous)
                            .fill(Color.accentColor)
                            .frame(width: width * segment.fill)
                    }
                    .frame(width: width)
                }
            }
            // One second, the same as the refresh, so the fill moves steadily
            // rather than in steps.
            .animation(animates ? .linear(duration: 1) : nil, value: segments)
        }
        .frame(height: Self.height)
    }
}
