import Foundation

/// The steps a recording goes through after it is saved, as the person sees
/// them. Finer than `ProcessingState`: removing echo from the microphone runs
/// inside the `transcribing` stage but takes long enough to be its own step.
public enum ProcessingStep: String, Codable, Sendable, CaseIterable, Comparable {
    case save
    case removeEcho = "remove_echo"
    case transcribe
    case identifySpeakers = "identify_speakers"
    case matchNames = "match_names"
    case writeNotes = "write_notes"

    /// The step a stage runs when nothing more specific is reported. Nil for
    /// the states that are not a step of processing.
    public init?(state: ProcessingState) {
        switch state {
        case .recording, .complete, .failed: return nil
        case .finalizing, .audioSafe: self = .save
        case .transcribing: self = .transcribe
        case .diarizing: self = .identifySpeakers
        case .resolvingSpeakers: self = .matchNames
        case .enriching: self = .writeNotes
        }
    }

    /// One name per step, used for the headline and the list alike.
    public var name: String {
        switch self {
        case .save: "Saving recording"
        case .removeEcho: "Removing echo from your microphone"
        case .transcribe: "Transcribing"
        case .identifySpeakers: "Identifying speakers"
        case .matchNames: "Matching names"
        case .writeNotes: "Writing notes"
        }
    }

    /// The steps a meeting from this source goes through. A recording with no
    /// call audio has no echo to remove.
    public static func steps(for source: MeetingSource) -> [ProcessingStep] {
        allCases.filter { $0 != .removeEcho || source.capturesRemoteAudio }
    }

    /// Whether the step's work grows with the length of the meeting. Saving,
    /// matching names and writing notes take about the same time for any
    /// meeting, so their history is kept in seconds rather than as a rate.
    public var scalesWithMeetingLength: Bool {
        switch self {
        case .removeEcho, .transcribe, .identifySpeakers: true
        case .save, .matchNames, .writeNotes: false
        }
    }

    /// The guess used before this Mac has timed the step itself: a fixed
    /// start-up part, such as loading a model, plus a part per minute of
    /// meeting. Set about three times slower than a recent Apple silicon Mac,
    /// so a slower machine does not see the bar reach the end of a step long
    /// before it finishes.
    func defaultSeconds(meetingSeconds: Double) -> Double {
        let minutes = meetingSeconds / 60
        switch self {
        case .save: return 3
        case .removeEcho: return 5 + 12 * minutes
        case .transcribe: return 10 + 3 * minutes
        case .identifySpeakers: return 60 + 12 * minutes
        case .matchNames: return 5
        case .writeNotes: return 20
        }
    }

    private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func < (lhs: ProcessingStep, rhs: ProcessingStep) -> Bool { lhs.order < rhs.order }
}

/// How long each step took on this Mac, kept so the progress bar can estimate
/// the steps that report no progress of their own. Stored per Mac, since one
/// Mac can be several times faster than another.
public struct ProcessingTimeHistory: Codable, Sendable, Equatable {
    public struct Sample: Codable, Sendable, Equatable {
        public var step: ProcessingStep
        public var seconds: Double
        public var meetingSeconds: Double

        public init(step: ProcessingStep, seconds: Double, meetingSeconds: Double) {
            self.step = step
            self.seconds = seconds
            self.meetingSeconds = meetingSeconds
        }
    }

    /// The newest samples per step. A change of engine or of Mac shows up
    /// after a few meetings rather than being averaged away.
    public static let keptPerStep = 10
    /// Meetings timed from start to finish before the time left is shown.
    /// Before that the estimate is the built-in guess, too rough to state.
    public static let runsBeforeTimeLeft = 3

    public private(set) var samples: [Sample]
    public private(set) var completedRuns: Int

    public init(samples: [Sample] = [], completedRuns: Int = 0) {
        self.samples = samples
        self.completedRuns = completedRuns
    }

    public var showsTimeLeft: Bool { completedRuns >= Self.runsBeforeTimeLeft }

    /// Adds one meeting's timings. Steps shorter than a second carry no
    /// signal, and a meeting with no length cannot give a rate.
    public mutating func record(_ durations: [ProcessingStep: Double], meetingSeconds: Double) {
        guard meetingSeconds > 0 else { return }
        for (step, seconds) in durations where seconds >= 1 {
            samples.append(Sample(step: step, seconds: seconds, meetingSeconds: meetingSeconds))
            let ofStep = samples.indices.filter { samples[$0].step == step }
            if ofStep.count > Self.keptPerStep, let oldest = ofStep.first {
                samples.remove(at: oldest)
            }
        }
        completedRuns += 1
    }

    /// Below this length a meeting's step time is mostly start-up, such as a
    /// model loading, so it says little about the rate for longer meetings.
    public static let shortMeetingSeconds: Double = 300

    /// The step's expected length for a meeting of this length: the median of
    /// this Mac's samples. Steps that scale with length use a rate per second
    /// of meeting, learned from meetings of the same kind, short or not; a
    /// short meeting's time is mostly fixed, so it is taken as it is.
    public func expectedSeconds(_ step: ProcessingStep, meetingSeconds: Double) -> Double {
        let mine = samples.filter { $0.step == step && $0.meetingSeconds > 0 }
        guard step.scalesWithMeetingLength else {
            return mine.isEmpty ? step.defaultSeconds(meetingSeconds: meetingSeconds) : Self.median(mine.map(\.seconds))
        }
        let isShort = meetingSeconds < Self.shortMeetingSeconds
        let alike = mine.filter { ($0.meetingSeconds < Self.shortMeetingSeconds) == isShort }
        guard !alike.isEmpty else { return step.defaultSeconds(meetingSeconds: meetingSeconds) }
        if isShort { return Self.median(alike.map(\.seconds)) }
        return Self.median(alike.map { $0.seconds / $0.meetingSeconds }) * meetingSeconds
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

/// How far a meeting's processing has got, as one bar across every step.
///
/// A step fills at the pace this Mac's history expects, and stops short of the
/// end until the step really finishes, so a wrong guess shows as a slow last
/// stretch rather than as a step claimed done. A step that reports its own
/// progress fills to whichever is further, the report or the guess: a model
/// that loads for a minute before reporting would otherwise send the bar back
/// to the start of its segment when the first report arrives.
public struct ProcessingEstimate: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public var step: ProcessingStep
        /// The segment's share of the bar's width.
        public var share: Double
        /// How full the segment is, from 0 to 1.
        public var fill: Double
    }

    /// The furthest an estimate goes on its own.
    public static let estimateCeiling = 0.95

    public var segments: [Segment]
    /// The whole bar, from 0 to 1.
    public var overall: Double
    public var secondsLeft: Double

    public init(
        steps: [ProcessingStep], current: ProcessingStep, secondsInStep: Double, reported: Double?,
        history: ProcessingTimeHistory, meetingSeconds: Double
    ) {
        let expected = steps.map { max(history.expectedSeconds($0, meetingSeconds: meetingSeconds), 1) }
        let total = expected.reduce(0, +)
        let currentIndex = steps.firstIndex(of: current) ?? 0
        let currentExpected = expected[currentIndex]
        let estimated = min(secondsInStep / currentExpected, Self.estimateCeiling)
        let fraction = min(max(reported ?? 0, estimated, 0), 1)
        segments = steps.enumerated().map { index, step in
            let fill: Double = index < currentIndex ? 1 : index == currentIndex ? fraction : 0
            return Segment(step: step, share: expected[index] / total, fill: fill)
        }
        overall = segments.reduce(0) { $0 + $1.share * $1.fill }
        let later = expected.dropFirst(currentIndex + 1).reduce(0, +)
        // A step running past its expected length has an unknown amount left;
        // a tenth of its length stands in rather than zero.
        let currentLeft = max(
            currentExpected * (1 - fraction), secondsInStep > currentExpected ? currentExpected * 0.1 : 0)
        secondsLeft = later + currentLeft
    }
}
