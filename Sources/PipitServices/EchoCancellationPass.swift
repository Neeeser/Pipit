import Foundation
import PipitAudio
import PipitCore

/// One run of the echo canceller over a recorded pair, block by block.
///
/// This is the alignment, the block loop and the measurement grid. Two callers
/// run it: `MicrophoneCleaner`, which keeps the cleaned samples and writes
/// them, and `EchoMeasurement`, which keeps only the levels. They share this
/// type so that a measurement describes the pass that ships. A second copy of
/// the loop would be a second copy of the offset arithmetic, and that
/// arithmetic has already been wrong once. Subtracting the two lead-ins the
/// other way round moves the pair by twice the offset and puts the echo in the
/// microphone ahead of the far end that caused it. No filter can model that,
/// and no outcome value reports it.
public struct EchoCancellationPass {
    /// The rate both tracks are read at, which is the rate every model above
    /// reads them at too.
    static let readFormat = AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1)
    /// Seconds one measurement window covers, matching the grid the speech
    /// evidence is already sampled on.
    static let windowSeconds = 0.25
    /// A track that never clears this in any window recorded nothing at all.
    static let referenceFloorDBFS = -80.0

    /// One quarter-second of the pass: how loud each track was, and what the
    /// canceller said it had removed by the end of it.
    ///
    /// The four travel together because none of them reads on its own.
    /// `farEndDBFS` decides whether the window is one the canceller can be
    /// judged on, `echoRemovedDB` is what it reported removing over that
    /// window, and the two microphone levels are what the window actually held
    /// before and after subtraction.
    ///
    /// What the canceller reported is not what it did, and keeping the two
    /// apart is the whole of the bypass rule. On the tone with no echo path in
    /// `AudioTests` the canceller reports 2.84 dB removed while taking 39.9 dB
    /// out of a microphone that holds only the user. The low reported figure is
    /// what says the filter never locked on, and that is the reason to throw
    /// its output away.
    public struct Window: Sendable, Equatable {
        public let farEndDBFS: Double
        public let echoRemovedDB: Double
        public let microphoneBeforeDBFS: Double
        public let microphoneAfterDBFS: Double

        public init(
            farEndDBFS: Double, echoRemovedDB: Double, microphoneBeforeDBFS: Double,
            microphoneAfterDBFS: Double
        ) {
            self.farEndDBFS = farEndDBFS
            self.echoRemovedDB = echoRemovedDB
            self.microphoneBeforeDBFS = microphoneBeforeDBFS
            self.microphoneAfterDBFS = microphoneAfterDBFS
        }
    }

    struct Result {
        var frames: Int64
        var windows: [Window]
    }

    /// How far the far end has to move to line up with the microphone.
    ///
    /// The microphone is read from its own first frame, so a position in the
    /// cleaned file is the same position in the recording and every timestamp
    /// downstream still lands where it did. The far end is moved onto that
    /// clock. `leadIn` says how long after the earliest track each one started,
    /// so their difference is how far the far end has to move: a far end that
    /// started later is padded with the silence Pipit did not record, and one
    /// that started earlier has that much of it read and thrown away.
    static func referenceOffset(timeline: RecordingTimeline) -> Double {
        timeline.leadIn(track: .remote) - timeline.leadIn(track: .mic)
    }

    /// Seconds the far end is handed to the canceller early, on top of
    /// wherever the pair was lined up.
    ///
    /// A canceller models an echo that arrives after its reference. The
    /// manifest lines the pair up on host time, and the tap's timestamps can
    /// run a few milliseconds behind the microphone's, so an exact alignment
    /// can land the echo just ahead of the reference. On the Zoom call of 11
    /// September 2026 the pair sat 2.4 ms the wrong way and the canceller
    /// then shipped took 10.6 dB off the far end where the same pass with
    /// the far end 10 ms earlier took 29.8 dB. The canceller now shipped
    /// finds the lag itself across the next second, so on speech the lead
    /// costs nothing.
    ///
    /// Applied inside `run`, so every caller lines the pair up and reports
    /// where it lined them up, and the lead is the pass's own business. The
    /// windows are still measured against the far end where it was lined up.
    static let referenceLeadSeconds = 0.01

    /// Runs the canceller over the pair and hands each cleaned block to `sink`.
    ///
    /// `sink` receives the samples the microphone actually recorded, on the
    /// recording's own clock: the canceller's output delay is taken back off
    /// the front and the tail padded with silence, so a position in the
    /// cleaned file is the same position in the recording. A caller that only
    /// wants the levels passes a sink that does nothing, and nothing is
    /// written anywhere.
    ///
    /// - Parameter referenceOffset: seconds the far end has to move to line up
    ///   with the microphone. `referenceOffset(timeline:)` is what a real run
    ///   uses. A caller passing anything else is deliberately measuring a
    ///   misalignment. The far end is then handed to the canceller
    ///   `referenceLeadSeconds` earlier than that.
    /// - Parameter canceller: the canceller to run. The shipped one by default.
    static func run(
        microphone: TrackAudioLocation, reference: TrackAudioLocation,
        referenceOffset: Double,
        canceller makeCanceller: () throws -> any EchoCancelling = {
            try EchoModels.shippedCanceller(sampleRate: Int(readFormat.sampleRate))
        },
        sink: (ArraySlice<Float>) throws -> Void
    ) throws -> Result {
        let canceller: any EchoCancelling
        do {
            canceller = try makeCanceller()
        } catch {
            throw ProcessingError.localProcessingFailed(
                reason: "the echo canceller could not be built: \(error)", retryable: false
            )
        }
        let block = canceller.blockFrames
        let windowFrames = Int((windowSeconds * readFormat.sampleRate).rounded())
        guard block > 0, windowFrames >= block else {
            throw ProcessingError.localProcessingFailed(
                reason: "the echo canceller reported a block of \(block) frames", retryable: false
            )
        }

        guard
            let microphoneReader = TimelineTrackReader(
                location: microphone, format: readFormat, offsetSeconds: 0
            ),
            let referenceReader = TimelineTrackReader(
                location: reference, format: readFormat,
                offsetSeconds: referenceOffset - referenceLeadSeconds
            ),
            let alignedReferenceReader = TimelineTrackReader(
                location: reference, format: readFormat, offsetSeconds: referenceOffset
            )
        else {
            throw ProcessingError.audioUnreadable(path: microphone.directory.lastPathComponent)
        }

        var result = Result(frames: 0, windows: [])
        // The window grid counts samples, not blocks, so a canceller whose
        // block does not divide a quarter second still measures on the same
        // grid the speech evidence is sampled on.
        var farEndSquares = 0.0
        var micBeforeSquares = 0.0
        var micAfterSquares = 0.0
        var samplesInWindow = 0
        var reportedRemoval = 0.0
        // The canceller's output delay: this many cleaned samples are held
        // back at the front, and the same number of zeros added at the end.
        var toDrop = canceller.latencyFrames
        var recordedTotal: Int64 = 0

        func account(before: ArraySlice<Float>, after: ArraySlice<Float>, played: ArraySlice<Float>) {
            var index = 0
            let count = before.count
            while index < count {
                let take = min(windowFrames - samplesInWindow, count - index)
                let range = index..<(index + take)
                micBeforeSquares += squares(
                    before[before.startIndex + range.lowerBound..<before.startIndex + range.upperBound])
                micAfterSquares += squares(
                    after[after.startIndex + range.lowerBound..<after.startIndex + range.upperBound])
                farEndSquares += squares(
                    played[played.startIndex + range.lowerBound..<played.startIndex + range.upperBound])
                samplesInWindow += take
                index += take
                if samplesInWindow == windowFrames {
                    result.windows.append(
                        Window(
                            farEndDBFS: decibels(squares: farEndSquares, count: samplesInWindow),
                            echoRemovedDB: reportedRemoval,
                            microphoneBeforeDBFS: decibels(squares: micBeforeSquares, count: samplesInWindow),
                            microphoneAfterDBFS: decibels(squares: micAfterSquares, count: samplesInWindow)
                        ))
                    samplesInWindow = 0
                    farEndSquares = 0
                    micBeforeSquares = 0
                    micAfterSquares = 0
                }
            }
        }

        // The recording and the far end as lined up, kept back as far as
        // the canceller's delay reaches, so a cleaned sample is compared with
        // the recorded sample for the same moment. With a delay longer than
        // a block those sit in an earlier block than the one just cleaned.
        var beforeHistory: [Float] = []
        var linedHistory: [Float] = []
        var historyStart: Int64 = 0
        var flushed: Int64 = 0

        func hand(_ cleaned: ArraySlice<Float>) throws {
            let count = cleaned.count
            guard count > 0 else { return }
            let from = Int(flushed - historyStart)
            account(
                before: beforeHistory[from..<(from + count)],
                after: cleaned,
                played: linedHistory[from..<(from + count)]
            )
            try sink(cleaned)
            flushed += Int64(count)
            let keep = Int(flushed - historyStart)
            beforeHistory.removeFirst(keep)
            linedHistory.removeFirst(keep)
            historyStart = flushed
        }

        while true {
            var samples = try microphoneReader.next(count: block)
            if samples.isEmpty { break }
            // The canceller takes whole blocks. The tail of the recording is
            // padded to one and trimmed back off before it reaches the sink.
            let recorded = samples.count
            if recorded < block {
                samples += [Float](repeating: 0, count: block - recorded)
            }
            var played = try referenceReader.next(count: block)
            // The far end's tap can stop before the microphone does, and what
            // it did not record is silence.
            if played.count < block {
                played += [Float](repeating: 0, count: block - played.count)
            }
            var lined = try alignedReferenceReader.next(count: block)
            if lined.count < block {
                lined += [Float](repeating: 0, count: block - lined.count)
            }
            beforeHistory.append(contentsOf: samples[0..<recorded])
            linedHistory.append(contentsOf: lined[0..<recorded])
            guard canceller.process(microphone: &samples, reference: played) else {
                throw ProcessingError.localProcessingFailed(
                    reason: "the echo canceller refused a block of \(block) frames",
                    retryable: false
                )
            }
            reportedRemoval = canceller.reportedRemovalDB ?? 0
            recordedTotal += Int64(recorded)

            // Take the output delay off the front, then hand on only as much
            // as has been recorded so far.
            var cleaned = samples[...]
            if toDrop > 0 {
                let drop = min(toDrop, cleaned.count)
                cleaned = cleaned.dropFirst(drop)
                toDrop -= drop
            }
            try hand(cleaned.prefix(Int(recordedTotal - flushed)))
        }
        // The delay's worth of silence at the end keeps the file the length
        // of the recording.
        let remaining = Int(recordedTotal - flushed)
        if remaining > 0 {
            try hand([Float](repeating: 0, count: remaining)[...])
        }
        result.frames = flushed
        return result
    }

    // MARK: - alignment

    /// Where the far end actually sits against the microphone, and whether that
    /// is worth believing.
    public struct Alignment: Sendable, Equatable {
        /// Seconds the far end has to move for the envelopes to line up, in the
        /// sense `run` takes it. Always where the peak is, so `correlation`
        /// describes this offset whether or not it was acted on. A caller reads
        /// `isUsable` to decide, and uses the timeline's own offset otherwise.
        public let offsetSeconds: Double
        /// How well the two envelopes agree at that offset.
        public let correlation: Double
        /// And at the offset the manifest gave, which is what this replaces.
        public let correlationAtTimeline: Double
        /// Whether every bar below was cleared. A measurement that was not is
        /// still returned, because the figures explain the decision.
        public let isUsable: Bool
    }

    /// Envelope window the search runs on. Fine enough to place a shift inside
    /// a syllable, and a twenty-fifth of the smallest shift acted on, so the
    /// quantisation is never what decides.
    static let alignmentWindowSeconds = 0.01
    /// How far either way the far end is looked for. The longest real slip
    /// measured on the recordings on disk is 5.35 s.
    static let alignmentSearchSeconds = 8.0
    /// How well the envelopes have to agree before the peak is a measurement
    /// rather than the loudest piece of noise.
    ///
    /// Measured over the 48 recordings on disk that hold both tracks. The ten
    /// with an audible echo path read 0.500 to 0.866 at their best offset and
    /// every one of the rest reads 0.320 or below, most of them near zero. This
    /// sits 1.25x below the lowest of the first group and 1.25x above the
    /// highest of the second. A call taken on headphones has no echo path, no
    /// peak to find and nothing for the canceller to remove either way, so
    /// refusing to move it costs nothing.
    static let minimumAlignmentCorrelation = 0.40
    /// And by how much it has to beat the offset already in hand, so a peak
    /// that is no better than where the manifest put the far end is not acted
    /// on.
    ///
    /// The three recordings that need moving gain 0.531, 0.618 and 0.604 over
    /// the manifest's offset. The seven already lined up gain 0.000 to 0.394,
    /// so this clause alone does not separate them: what leaves those alone is
    /// `minimumAlignmentShiftSeconds`, because their peaks sit within a tenth
    /// of a second of where they already are. This one refuses a peak that is
    /// far away and no better, which is the shape a recording with two
    /// unrelated tracks produces.
    static let minimumAlignmentGain = 0.15
    /// Below this the filter absorbs the difference itself, and moving the
    /// whole track to chase it would be arithmetic dressed as precision.
    static let minimumAlignmentShiftSeconds = 0.25

    /// Measures the far end against the microphone and says where it sits.
    ///
    /// The manifest says when each track's first frame arrived, and until 10
    /// September 2026 that was taken as the whole answer. It is not: a source
    /// that stalls mid-recording leaves a hole, and a hole nothing was written
    /// for moves every later second of that track earlier without changing the
    /// first frame at all. On the standup of that morning the microphone ran
    /// 2.45 s ahead of the far end for 31 of its 32 minutes while the manifest
    /// reported the two tracks starting 1.3 ms apart. The canceller was handed
    /// the manifest's answer, never locked on, and took 6.5 dB off the far end
    /// where the same pass at the measured offset takes 15.3 dB.
    ///
    /// `SegmentWriter` no longer loses that hole, so this is not the fix for
    /// new recordings. It is what lets one already on disk be cleaned properly
    /// when it is analysed again, and what keeps any later fault of the same
    /// shape from being silent.
    ///
    /// The comparison is between loudness envelopes rather than samples. The
    /// echo is the far end played out of a speaker and heard again across a
    /// room, so it arrives filtered, quieter and reverberant, and its waveform
    /// no longer resembles what was played. Its loudness over time still does.
    static func measureAlignment(
        microphone: TrackAudioLocation, reference: TrackAudioLocation, timelineOffset: Double
    ) throws -> Alignment {
        // Nothing to compare, so the timeline's own offset is the only answer
        // and it is reported as measured at zero agreement.
        let unusable = Alignment(
            offsetSeconds: timelineOffset, correlation: 0, correlationAtTimeline: 0, isUsable: false
        )
        // Both read on the timeline the pass itself will use, so what comes back
        // is what still has to be corrected rather than a second absolute
        // answer that has to be reconciled with the first.
        guard
            let microphoneReader = TimelineTrackReader(
                location: microphone, format: readFormat, offsetSeconds: 0
            ),
            let referenceReader = TimelineTrackReader(
                location: reference, format: readFormat, offsetSeconds: timelineOffset
            )
        else { return unusable }
        let near = try envelope(of: microphoneReader)
        let far = try envelope(of: referenceReader)
        let count = min(near.count, far.count)
        let span = Int((alignmentSearchSeconds / alignmentWindowSeconds).rounded())
        // Two search widths of usable recording, so the correlation at the
        // edges of the search is still measured over most of the meeting.
        guard count > span * 2 else { return unusable }
        let a = centred(Array(near[..<count]))
        let b = centred(Array(far[..<count]))
        let scale = (magnitude(a) * magnitude(b))
        guard scale > 0 else { return unusable }

        var bestLag = 0
        var best = -Double.greatestFiniteMagnitude
        for lag in -span...span {
            let value = dot(a, b, lag: lag) / scale
            if value > best {
                best = value
                bestLag = lag
            }
        }
        let atTimeline = dot(a, b, lag: 0) / scale
        // `dot` slides the far end forward by `lag`, so the lag that lines the
        // two up is already the direction and the distance the far end has to
        // move. A microphone that lost audio holds the room early, which puts
        // the peak at a negative lag and moves the far end back to meet it.
        let shift = Double(bestLag) * alignmentWindowSeconds
        let usable =
            best >= minimumAlignmentCorrelation
            && best - atTimeline >= minimumAlignmentGain
            && abs(shift) >= minimumAlignmentShiftSeconds
        return Alignment(
            offsetSeconds: timelineOffset + shift,
            correlation: best,
            correlationAtTimeline: atTimeline,
            isUsable: usable
        )
    }

    /// Root-mean-square loudness, one window at a time, to the end of the track.
    private static func envelope(of reader: TimelineTrackReader) throws -> [Double] {
        let window = Int((alignmentWindowSeconds * readFormat.sampleRate).rounded())
        var out: [Double] = []
        while true {
            let samples = try reader.next(count: window)
            if samples.isEmpty { return out }
            out.append((squares(samples) / Double(samples.count)).squareRoot())
            if samples.count < window { return out }
        }
    }

    private static func centred(_ values: [Double]) -> [Double] {
        guard !values.isEmpty else { return values }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.map { $0 - mean }
    }

    private static func magnitude(_ values: [Double]) -> Double {
        values.reduce(0) { $0 + $1 * $1 }.squareRoot()
    }

    /// Sum of `a` against `b` slid by `lag` windows, over the part they share.
    private static func dot(_ a: [Double], _ b: [Double], lag: Int) -> Double {
        let from = max(0, lag)
        let to = min(a.count, b.count + lag)
        guard to > from else { return 0 }
        var total = 0.0
        for index in from..<to { total += a[index] * b[index - lag] }
        return total
    }

    /// Whether the far end's track holds any audio at all.
    ///
    /// A track that never clears the floor in any window is one the tap opened
    /// on and recorded nothing through. An early exit rather than a rule of its
    /// own: a track this refuses has no window loud enough to count below
    /// either, so the answer is the same. What it saves is cancelling and
    /// encoding a two-hour meeting against silence before saying so.
    static func referenceHoldsAudio(_ location: TrackAudioLocation) throws -> Bool {
        guard
            let reader = TimelineTrackReader(
                location: location, format: readFormat, offsetSeconds: 0
            )
        else { return false }
        let window = Int((windowSeconds * readFormat.sampleRate).rounded())
        while true {
            let samples = try reader.next(count: window)
            if samples.isEmpty { return false }
            if decibels(squares: squares(samples), count: samples.count) > referenceFloorDBFS {
                return true
            }
            if samples.count < window { return false }
        }
    }

    static func decibels(squares: Double, count: Int) -> Double {
        guard count > 0 else { return EmptyTranscriptPolicy.silenceFloorDBFS }
        let rms = (squares / Double(count)).squareRoot()
        guard rms > 0 else { return EmptyTranscriptPolicy.silenceFloorDBFS }
        return max(EmptyTranscriptPolicy.silenceFloorDBFS, 20 * log10(rms))
    }

    /// What one pass decided, and the figures it decided on.
    public struct Judgement: Equatable {
        public let outcome: CleaningOutcome
        public let reason: String
        /// Median of the canceller's own reported enhancement over the
        /// far-end-active windows. Informational: it reads near zero on real
        /// recordings the pass demonstrably cleaned, so nothing is decided
        /// on it.
        public let reportedMedianDB: Double
        /// Median of what the microphone's level actually did over the
        /// far-end-active windows, before minus after, in decibels. On a call
        /// on headphones there is nothing to remove and this reads near zero;
        /// on a call on speakers it is what the pass took out.
        public let measuredMedianDB: Double
        public let activeWindows: Int
        public let microphoneFloorDBFS: Double
        /// Windows where the far end was quiet and the microphone held
        /// something, which is the user alone. The only class in which a
        /// level drop is a loss.
        public let userWindows: Int
        public let userHarmMedianDB: Double?
        /// Share of those windows that lost more than `notableLossDB`.
        public let userHarmShare: Double?
    }

    /// Windows of far-end activity the decision needs before it is made at all.
    ///
    /// Ten seconds. The canceller reports nothing for its first 2.5 s of
    /// far-end activity, and counting in far-end-active windows rather than in
    /// seconds of file is what makes the bound hold for a meeting whose far end
    /// stayed quiet for the first minute.
    public static let minimumActiveWindows = 40
    /// A window whose far-end level clears this had the far end playing in it.
    public static let farEndActiveDBFS = -60.0
    /// Windows of the user alone the harm figures need before they mean
    /// anything. Five seconds.
    public static let minimumUserWindows = 20
    /// How far above its own quietest twentieth a microphone has to be before a
    /// window counts as holding something. Speech at a desk runs 20 to 40 dB
    /// over the room it is in.
    public static let microphoneActivationMarginDB = 10.0
    /// The loss to the user's own windows above which the cleaned track is
    /// thrown away: the median drop, and the share of windows that dropped by
    /// more than `notableLossDB`.
    ///
    /// Measured over four recordings on speakers, two the canceller locked on
    /// to and two it reported nothing on: the user-only median moved 0.0 to
    /// 0.5 dB and 1% to 3% of windows lost more than 6 dB. The tone fixtures
    /// gate two boundary windows of twenty-six, which is 8%. The
    /// continuous-tone fixture in `AudioTests`, where the suppressor has an
    /// unrelated reference and nothing else, takes 39.9 dB out of every
    /// window. The limits sit between.
    public static let harmMedianLimitDB = 2.0
    public static let notableLossDB = 10.0
    public static let harmShareLimit = 0.10

    /// Decides whether the pass is worth keeping, from what it measured.
    ///
    /// The canceller's own enhancement figure used to decide this, against a
    /// 6 dB threshold set from tones. On real recordings it read 0.2 to 1.8 dB
    /// on calls the pass had cleaned by 4 to 18 dB in the windows where the far
    /// end played over the user, so the rule refused the meetings it would
    /// have helped. What the bypass exists to prevent is damage to the user's
    /// own speech, and that is measured directly: over the windows where the
    /// far end was quiet and the microphone held something, the level must not
    /// have dropped.
    public static func judge(windows: [Window]) -> Judgement {
        let active = windows.filter { $0.farEndDBFS > farEndActiveDBFS }
        let reported = median(of: active.map(\.echoRemovedDB))
        let measured = median(of: active.map { $0.microphoneBeforeDBFS - $0.microphoneAfterDBFS })
        let quiet = percentile(windows.map(\.microphoneBeforeDBFS), 0.05)
        let floor = microphoneFloorDBFS(quietWindowDBFS: quiet)
        let user = windows.filter {
            $0.farEndDBFS <= farEndActiveDBFS && $0.microphoneBeforeDBFS > floor
        }
        let harm = user.map { $0.microphoneBeforeDBFS - $0.microphoneAfterDBFS }
        let judgeable = user.count >= minimumUserWindows
        let harmMedian = judgeable ? percentile(harm, 0.5) : nil
        let harmShare =
            judgeable
            ? Double(harm.filter { $0 > notableLossDB }.count) / Double(harm.count) : nil
        func judgement(_ outcome: CleaningOutcome, _ reason: String) -> Judgement {
            Judgement(
                outcome: outcome, reason: reason, reportedMedianDB: reported,
                measuredMedianDB: measured,
                activeWindows: active.count, microphoneFloorDBFS: floor,
                userWindows: user.count, userHarmMedianDB: harmMedian, userHarmShare: harmShare
            )
        }
        guard active.count >= minimumActiveWindows else {
            return judgement(
                .skippedNoReference,
                "the far end was above \(fixed(farEndActiveDBFS)) dBFS in \(active.count) "
                    + "windows, and the decision needs \(minimumActiveWindows)"
            )
        }
        if let harmMedian, let harmShare,
            harmMedian > harmMedianLimitDB || harmShare > harmShareLimit
        {
            return judgement(
                .bypassedNoEchoPath,
                "the user's own windows lost \(fixed(harmMedian)) dB at the median, and "
                    + "\(Int((harmShare * 100).rounded()))% of them more than "
                    + "\(fixed(notableLossDB)) dB, over \(user.count) windows"
            )
        }
        let held =
            harmMedian.map { "lost \(fixed($0)) dB at the median" }
            ?? "held too few windows to judge"
        return judgement(
            .cleaned,
            "the user's own windows \(held) over \(user.count) windows, and the far end "
                + "played in \(active.count)"
        )
    }

    /// The level the microphone clears to count as holding something: this
    /// recording's own quietest twentieth plus `microphoneActivationMarginDB`,
    /// and never below the far end's floor, because nothing under it is speech
    /// either way.
    public static func microphoneFloorDBFS(quietWindowDBFS: Double?) -> Double {
        guard let quietWindowDBFS else { return farEndActiveDBFS }
        return max(farEndActiveDBFS, quietWindowDBFS + microphoneActivationMarginDB)
    }

    /// The value at a fraction of the way up the sorted series, by nearest
    /// rank, so every figure reported is a window that actually happened.
    public static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }

    private static func fixed(_ value: Double) -> String { String(format: "%.1f", value) }

    static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    static func squares<Samples: Collection>(_ samples: Samples) -> Double where Samples.Element == Float {
        samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    }
}
