import Foundation
import PipitAudio
import PipitCore

/// The pass over a recording made of several runs.
///
/// A call that dropped and was rejoined is two or more runs under one manifest.
/// Each run opens writers of its own, and a source that stalls leaves a hole
/// that moves every later second of its track, so the far end can sit a
/// different distance from the microphone in each run. On a 59 minute call of
/// 5 October 2026 the far end had to move +1.76 s onto the microphone's clock in
/// the first run and -1.46 s in the second. A single placement for the whole meeting is right for one run and
/// wrong for the others, and the canceller was handed a reference seconds out of
/// step for everything after the rejoin.
///
/// So the far end is placed against the microphone once per run, from that run's
/// own host times and from a measurement over that run's own audio. The cleaned
/// track is still one file on the microphone's clock, and the decision about
/// whether to keep it is still one per meeting.
extension EchoCancellationPass {
    /// Where the far end sits against the microphone from one point on.
    struct Placement: Sendable, Equatable {
        /// First second of the microphone this placement covers. It holds until
        /// the next placement starts, or to the end of the recording.
        let startSeconds: Double
        /// Seconds the far end moves to line up with the microphone, in the
        /// sense `run` takes it. Nil where the far end recorded nothing, which
        /// is handed to the canceller as silence rather than as whatever the
        /// far end played at some other time.
        let offsetSeconds: Double?
        /// The part of the far end's track this run wrote, in the track's own
        /// seconds. Nothing outside it is handed to the canceller: the audio
        /// before it was recorded in an earlier run and the audio after it in a
        /// later one, and neither was playing here.
        let farEnd: ClosedRange<Double>

        init(
            startSeconds: Double, offsetSeconds: Double?,
            farEnd: ClosedRange<Double> = 0...Double.infinity
        ) {
            self.startSeconds = startSeconds
            self.offsetSeconds = offsetSeconds
            self.farEnd = farEnd
        }
    }

    /// The placement the manifest gives each run, in the microphone's order.
    ///
    /// The microphone is read from its own first frame, so a position in the
    /// cleaned file is the same position in the recording and every timestamp
    /// downstream still lands where it did. The far end is moved onto that
    /// clock. `CaptureRun.referenceOffset` says how far: a far end that
    /// started later is padded with the silence Pipit did not record, and one
    /// that started earlier has that much of it read and thrown away.
    ///
    /// A run whose host times could not be read takes the offset of the run
    /// before it, and zero when it is the first. A recording is always at
    /// least one placement.
    static func placements(timeline: RecordingTimeline) -> [Placement] {
        var placements: [Placement] = []
        var previous: Double?
        let runs = timeline.runs.filter { ($0.mic?.seconds ?? 0) > 0 }
        for (index, run) in runs.enumerated() {
            guard let microphone = run.mic else { continue }
            var offset: Double?
            var farEnd = 0...Double.infinity
            if let remote = run.remote, remote.seconds > 0 {
                offset = run.referenceOffset ?? previous ?? 0
                previous = offset
                // The last run draws on the far end to the end of its track,
                // which can run a little past what the manifest counted.
                let end = index == runs.count - 1 ? Double.infinity : remote.startSeconds + remote.seconds
                farEnd = remote.startSeconds...end
            }
            placements.append(
                Placement(startSeconds: microphone.startSeconds, offsetSeconds: offset, farEnd: farEnd)
            )
        }
        return placements.isEmpty ? [Placement(startSeconds: 0, offsetSeconds: 0)] : placements
    }

    /// One run of the microphone, lined up against the far end.
    struct AlignedRun: Sendable, Equatable {
        let startSeconds: Double
        /// How long the run is on the microphone's clock.
        let seconds: Double
        /// What the manifest says. Nil where the far end recorded nothing.
        let timelineOffsetSeconds: Double?
        /// The part of the far end's track this run draws on.
        let farEnd: ClosedRange<Double>
        /// What the envelopes say, over this run alone. Present whether or not
        /// it was acted on, because the figures explain the decision.
        let measured: Alignment

        /// Where the far end was put: the measurement where it cleared its
        /// bars, the manifest otherwise.
        var offsetSeconds: Double? {
            guard let timelineOffsetSeconds else { return nil }
            return measured.isUsable ? measured.offsetSeconds : timelineOffsetSeconds
        }

        var placement: Placement {
            Placement(startSeconds: startSeconds, offsetSeconds: offsetSeconds, farEnd: farEnd)
        }
    }

    /// Places the far end against the microphone in every run, and measures
    /// each run on its own audio.
    ///
    /// Each run's measurement is read through that run's own manifest offset,
    /// so what comes back is what is still left to correct in this run.
    static func alignRuns(
        microphone: TrackAudioLocation, reference: TrackAudioLocation, timeline: RecordingTimeline
    ) throws -> [AlignedRun] {
        let placements = placements(timeline: timeline)
        var runs: [AlignedRun] = []
        for (index, placement) in placements.enumerated() {
            let isLast = index == placements.count - 1
            let end = isLast ? nil : placements[index + 1].startSeconds
            let length = end.map { $0 - placement.startSeconds }
            let measured: Alignment
            if let offset = placement.offsetSeconds {
                measured = try measureAlignment(
                    microphone: microphone, reference: reference, timelineOffset: offset,
                    from: placement.startSeconds, length: length, farEnd: placement.farEnd
                )
            } else {
                measured = .unmeasured(timelineOffset: 0)
            }
            runs.append(
                AlignedRun(
                    startSeconds: placement.startSeconds,
                    seconds: length ?? max(0, microphone.seconds - placement.startSeconds),
                    timelineOffsetSeconds: placement.offsetSeconds,
                    farEnd: placement.farEnd,
                    measured: measured
                ))
        }
        return runs
    }

    /// The placements to run the pass with, once each run is lined up.
    static func placements(of runs: [AlignedRun]) -> [Placement] {
        runs.map(\.placement)
    }

    /// How well the envelopes agree across the runs that could be measured,
    /// each weighted by the audio it was measured over.
    static func correlation(of alignments: [Alignment]) -> Double {
        let total = alignments.reduce(0) { $0 + $1.measuredSeconds }
        guard total > 0 else { return 0 }
        return alignments.reduce(0) { $0 + $1.correlation * $1.measuredSeconds } / total
    }

    /// The same measurement over a cleaned microphone, run by run, at the
    /// offsets the pass used.
    static func correlation(
        cleaned: TrackAudioLocation, reference: TrackAudioLocation, runs: [AlignedRun]
    ) throws -> Double {
        var alignments: [Alignment] = []
        for (index, run) in runs.enumerated() {
            guard let offset = run.offsetSeconds else { continue }
            alignments.append(
                try measureAlignment(
                    microphone: cleaned, reference: reference, timelineOffset: offset,
                    from: run.startSeconds, length: index == runs.count - 1 ? nil : run.seconds,
                    farEnd: run.farEnd
                ))
        }
        return correlation(of: alignments)
    }
}
