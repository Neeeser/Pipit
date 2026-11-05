import Foundation

/// The stretch of a recording a person chose to keep, in seconds on the
/// meeting's timeline.
public struct TrimRange: Sendable, Equatable {
    public let start: Double
    public let end: Double
    /// The person kept everything through the end of the recording. Each
    /// track then keeps its own last frame, which can be later than `end`
    /// because the meeting's length is the longest single track and leaves
    /// out how late the other one began.
    public let keepsEnd: Bool

    /// Nil when the range keeps nothing or keeps everything: a trim has to
    /// remove something and leave something. `toEnd` says the end handle sat
    /// at the end of the timeline, which can be past `duration`.
    public init?(start: Double, end: Double, duration: Double, toEnd: Bool = false) {
        let start = max(0, start)
        let keepsEnd = toEnd || end >= duration - MeetingTrim.tolerance
        let end = toEnd ? max(duration, end) : min(duration, end)
        guard end - start >= MeetingTrim.shortestKept else { return nil }
        guard start > MeetingTrim.tolerance || !keepsEnd else { return nil }
        self.start = start
        self.end = end
        self.keepsEnd = keepsEnd
    }

    public var seconds: Double { end - start }

    /// Where the kept stretch stops, which is no limit at all when it runs to
    /// the end of the recording.
    public var effectiveEnd: Double { keepsEnd ? .infinity : end }

    /// Where a time on the old timeline lands on the trimmed one, or nil when
    /// it was cut.
    public func moved(_ time: Double) -> Double? {
        guard time >= start, time < effectiveEnd else { return nil }
        return time - start
    }
}

/// Cuts a finished meeting's stored data down to a kept range.
///
/// Trim is the one deliberate exception to source audio and raw model output
/// being immutable: the person picked the range and confirmed that the rest is
/// deleted. Everything here is a pure function of the old value and the range,
/// so each file can be rewritten on its own and the result is the same as if
/// the recording had only ever covered the kept range. Speaker clusters keep
/// their identifiers, so names given to them survive the trim.
public enum MeetingTrim {
    /// The shortest recording a trim may leave.
    public static let shortestKept: Double = 1
    /// Slack under which a handle counts as sitting on the recording's edge.
    public static let tolerance: Double = 0.05

    // MARK: timeline data

    /// A span on the old timeline, clipped to the range and moved onto the new
    /// one. Nil when none of it is kept.
    static func clip(start: Double, end: Double, to range: TrimRange) -> (start: Double, end: Double)? {
        let clippedStart = max(start, range.start)
        let clippedEnd = min(end, range.effectiveEnd)
        guard clippedEnd > clippedStart else { return nil }
        return (clippedStart - range.start, clippedEnd - range.start)
    }

    /// The raw transcript cut to the range, with the timings of its text-only
    /// chunks cut the same way.
    public struct TrimmedTranscript: Sendable, Equatable {
        public var transcript: RawTranscript
        /// The alignment of every kept chunk that had one, by chunk id.
        public var alignments: [String: ChunkAlignment]
    }

    public static func trim(_ transcript: RawTranscript, to range: TrimRange) -> RawTranscript {
        trim(transcript, alignments: [:], to: range).transcript
    }

    /// A cloud chunk is text alone, and its word timings live in a separate
    /// alignment file. Both have to be cut together: a chunk that straddles
    /// the cut keeps only the words inside the range, and the alignment moves
    /// with them. Chunks wholly outside the range, and their alignments, go.
    public static func trim(
        _ transcript: RawTranscript, alignments: [String: ChunkAlignment], to range: TrimRange
    ) -> TrimmedTranscript {
        var trimmed = transcript
        var kept: [String: ChunkAlignment] = [:]
        trimmed.chunks = transcript.chunks.compactMap { chunk in
            guard let result = trim(chunk, alignment: alignments[chunk.id], to: range) else { return nil }
            if let alignment = result.alignment { kept[chunk.id] = alignment }
            return result.chunk
        }
        return TrimmedTranscript(transcript: trimmed, alignments: kept)
    }

    static func trim(_ chunk: RawTranscriptChunk, to range: TrimRange) -> RawTranscriptChunk? {
        trim(chunk, alignment: nil, to: range)?.chunk
    }

    /// Where a chunk's own seconds land after the cut.
    private struct ChunkShift {
        /// Where the chunk began on the old timeline.
        var offset: Double
        /// The kept part of the chunk on the new timeline.
        var span: (start: Double, end: Double)
        /// Added to a time measured from the old chunk start to measure it from
        /// the new one.
        var shift: Double
        /// A position inside the chunk, in the chunk's old seconds, that the
        /// range starts at, and the one it stops at.
        var keptFrom: Double
        var keptTo: Double
        var isClipped: Bool
    }

    static func trim(
        _ chunk: RawTranscriptChunk, alignment: ChunkAlignment?, to range: TrimRange
    ) -> (chunk: RawTranscriptChunk, alignment: ChunkAlignment?)? {
        let offset = chunk.timelineOffset
        guard let span = clip(start: offset, end: offset + chunk.durationSeconds, to: range) else { return nil }
        let moved = ChunkShift(
            offset: offset, span: span, shift: offset - range.start - span.start,
            keptFrom: max(0, range.start - offset),
            keptTo: min(chunk.durationSeconds, range.effectiveEnd - offset),
            isClipped: offset < range.start || offset + chunk.durationSeconds > range.effectiveEnd
        )
        var trimmed = chunk
        trimmed.timelineOffset = span.start
        trimmed.durationSeconds = span.end - span.start
        // The raw response holds every word the model heard, and is deleted
        // with the rest of the removed stretch.
        trimmed.rawResponseFile = nil
        trimmed.segments = trim(chunk.segments, moved: moved, range: range)
        guard let text = chunk.text, chunk.segments.isEmpty else { return (trimmed, nil) }

        // A text-only chunk: its words are timed by the alignment, or not at
        // all.
        var trimmedAlignment = alignment
        if let alignment, !alignment.segments.isEmpty {
            let segments = trim(alignment.segments, moved: moved, range: range)
            trimmedAlignment?.segments = segments
            if moved.isClipped {
                trimmed.text = segments.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            }
        } else if moved.isClipped {
            trimmed.text = evenlySpaced(text, over: 0...chunk.durationSeconds, keeping: moved.keptFrom...moved.keptTo)
        }
        if trimmed.text?.trimmingCharacters(in: .whitespaces).isEmpty == true { return nil }
        return (trimmed, trimmedAlignment)
    }

    /// The segments of one chunk that the range keeps, with their times moved
    /// to measure from the chunk's new start.
    private static func trim(
        _ segments: [RawTranscriptSegment], moved chunk: ChunkShift, range: TrimRange
    ) -> [RawTranscriptSegment] {
        let origin = chunk.offset
        return segments.compactMap { segment in
            guard
                let kept = clip(start: origin + segment.start, end: origin + segment.end, to: range)
            else { return nil }
            var moved = segment
            moved.start = kept.start - chunk.span.start
            moved.end = kept.end - chunk.span.start
            let isClipped =
                origin + segment.start < range.start - 1e-9 || origin + segment.end > range.effectiveEnd + 1e-9
            if let words = segment.words {
                let keptWords = words.compactMap { word -> RawTranscriptWord? in
                    guard range.moved(origin + word.start) != nil else { return nil }
                    var movedWord = word
                    movedWord.start = word.start + chunk.shift
                    movedWord.end = min(word.end + chunk.shift, moved.end)
                    return movedWord
                }
                if keptWords.isEmpty { return nil }
                if keptWords.count != words.count {
                    moved.text = keptWords.map(\.text).joined()
                }
                moved.words = keptWords
            } else if isClipped {
                // No word timings: the words that fall inside are the ones
                // that would, spaced evenly through the segment.
                moved.text = evenlySpaced(
                    segment.text, over: segment.start...segment.end,
                    keeping: chunk.keptFrom...chunk.keptTo
                )
                if moved.text.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            }
            return moved
        }
    }

    /// The words of `text` that lie wholly inside `kept`, taking them to be
    /// spread evenly over `span`. Used where nothing says when each word was
    /// said. A word straddling an edge goes, because the alternative is
    /// keeping speech the person asked to delete.
    static func evenlySpaced(_ text: String, over span: ClosedRange<Double>, keeping kept: ClosedRange<Double>)
        -> String
    {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, span.upperBound > span.lowerBound else { return "" }
        let width = (span.upperBound - span.lowerBound) / Double(words.count)
        let keptWords = words.enumerated().filter { index, _ in
            let start = span.lowerBound + Double(index) * width
            return start >= kept.lowerBound - 1e-9 && start + width <= kept.upperBound + 1e-9
        }
        return keptWords.map { String($0.element) }.joined(separator: " ")
    }

    public static func trim(_ transcript: CanonicalTranscript, to range: TrimRange) -> CanonicalTranscript {
        var trimmed = transcript
        trimmed.utterances = transcript.utterances.compactMap { utterance in
            guard let kept = clip(start: utterance.start, end: utterance.end, to: range) else { return nil }
            var moved = utterance
            moved.start = kept.start
            moved.end = kept.end
            if let words = utterance.words {
                let keptWords = words.compactMap { word -> RawTranscriptWord? in
                    guard let start = range.moved(word.start) else { return nil }
                    var movedWord = word
                    movedWord.start = start
                    movedWord.end = min(word.end - range.start, kept.end)
                    return movedWord
                }
                if keptWords.isEmpty { return nil }
                if keptWords.count != words.count {
                    moved.text = keptWords.map(\.text).joined().trimmingCharacters(in: .whitespaces)
                }
                moved.words = keptWords
            }
            return moved
        }
        return trimmed
    }

    public static func trim(_ diarization: RawDiarization, to range: TrimRange) -> RawDiarization {
        var trimmed = diarization
        trimmed.runs = diarization.runs.map { run in
            var moved = run
            moved.timelineOffset = max(0, run.timelineOffset - range.start)
            moved.intervals = run.intervals.compactMap { interval in
                guard let kept = clip(start: interval.start, end: interval.end, to: range) else { return nil }
                var clipped = interval
                clipped.start = kept.start
                clipped.end = kept.end
                return clipped
            }
            return moved
        }
        return trimmed
    }

    public static func trim(_ sensors: RawSensors, to range: TrimRange) -> RawSensors {
        var trimmed = sensors
        trimmed.turns = sensors.turns.compactMap { turn in
            guard let kept = clip(start: turn.start, end: turn.end, to: range) else { return nil }
            var moved = turn
            moved.start = kept.start
            moved.end = kept.end
            return moved
        }
        return trimmed
    }

    /// The names stay. The corrections a person made to single lines and the
    /// places they cut a line move with the words, and those in the removed
    /// stretch go with it.
    public static func trim(_ map: SpeakerMap, to range: TrimRange) -> SpeakerMap {
        var trimmed = map
        trimmed.utteranceOverrides = map.utteranceOverrides.compactMap { override in
            // A correction covers a span, and a line the cut only shortens is
            // still there, so the correction stays on what is left of it. One
            // with no span, from before spans were recorded, rests on its
            // anchor alone.
            guard let first = override.startSeconds, let last = override.endSeconds else {
                guard let anchor = range.moved(override.anchorSeconds) else { return nil }
                var moved = override
                moved.anchorSeconds = anchor
                return moved
            }
            guard let kept = clip(start: first, end: last, to: range) else { return nil }
            var moved = override
            moved.startSeconds = kept.start
            moved.endSeconds = kept.end
            moved.anchorSeconds = range.moved(override.anchorSeconds) ?? (kept.start + kept.end) / 2
            return moved
        }
        trimmed.lineCuts = map.lineCuts.compactMap { cut in
            guard let at = range.moved(cut.atSeconds) else { return nil }
            var moved = cut
            moved.atSeconds = at
            return moved
        }
        return trimmed
    }

    /// A suggestion rests on a quote at a moment; one from the removed stretch
    /// rests on nothing that is left.
    public static func trim(_ set: SpeakerSuggestionSet, to range: TrimRange) -> SpeakerSuggestionSet {
        var trimmed = set
        trimmed.suggestions = set.suggestions.compactMap { suggestion in
            guard let at = range.moved(suggestion.atSeconds) else { return nil }
            var moved = suggestion
            moved.atSeconds = at
            return moved
        }
        return trimmed
    }

    public static func trim(_ evidence: SpeechEvidence, to range: TrimRange) -> SpeechEvidence {
        var trimmed = evidence
        trimmed.micLevels = windows(evidence.micLevels, width: evidence.levelWindowSeconds, range: range)
        trimmed.remoteLevels = windows(evidence.remoteLevels, width: evidence.levelWindowSeconds, range: range)
        trimmed.micSpeech = windows(evidence.micSpeech, width: evidence.speechWindowSeconds, range: range)
        return trimmed
    }

    /// The windows that cover the kept range. A window straddling either edge
    /// is kept, so the evidence is off by under one window at most.
    static func windows(_ values: [Int8], width: Double, range: TrimRange) -> [Int8] {
        guard width > 0, !values.isEmpty else { return values }
        let first = min(values.count, Int((range.start / width).rounded(.down)))
        let last = range.keepsEnd ? values.count : min(values.count, Int((range.end / width).rounded(.up)))
        guard last > first else { return [] }
        return Array(values[first..<last])
    }

    // MARK: audio

    /// Where a track's kept audio sits in its own file, in seconds.
    public struct TrackCut: Sendable, Equatable {
        public let from: Double
        public let to: Double
        public var seconds: Double { to - from }
    }

    /// The meeting timeline starts at the earliest first frame of any track.
    /// A track that started later is shifted by the difference.
    public static func origin(_ archive: AudioArchive) -> Double? {
        [archive.mic?.firstFrameHostTime, archive.remote?.firstFrameHostTime].compactMap { $0 }.min()
    }

    /// How long the meeting runs on its timeline: the end of whichever track
    /// finishes last, counting how late each began.
    public static func timelineLength(_ archive: AudioArchive) -> Double {
        let origin = origin(archive)
        return CaptureTrack.allCases.compactMap { name -> Double? in
            guard let track = archive.track(name) else { return nil }
            let lead = origin.flatMap { origin in track.firstFrameHostTime.map { $0 - origin } } ?? 0
            return lead + track.seconds
        }.max() ?? 0
    }

    /// The part of one archived track that the range keeps. A range that keeps
    /// the end keeps the track to its own last frame.
    public static func cut(
        _ track: AudioArchive.Track, origin: Double?, range: TrimRange
    ) -> TrackCut? {
        let lead = origin.flatMap { origin in track.firstFrameHostTime.map { $0 - origin } } ?? 0
        let from = max(0, range.start - lead)
        let to = min(track.seconds, range.effectiveEnd - lead)
        guard to > from else { return nil }
        return TrackCut(from: from, to: to)
    }

    /// The archive record for a track whose file now holds only `cut`.
    /// `firstFrameHostTime` is the capture time of the first kept frame where
    /// the manifest knows it; a track whose audio had a gap before the cut is
    /// not placed right by adding the cut's length to its old start.
    public static func trimmed(
        _ track: AudioArchive.Track, cut: TrackCut, frameCount: Int64, firstFrameHostTime: Double? = nil
    ) -> AudioArchive.Track {
        var moved = track
        moved.frameCount = frameCount
        moved.seconds = Double(frameCount) / track.sampleRate
        moved.firstFrameHostTime = firstFrameHostTime ?? track.firstFrameHostTime.map { $0 + cut.from }
        return moved
    }

    // MARK: metadata

    /// The change to the meeting's own record, given the archive records the
    /// rewritten audio files produced. The duration is the longest kept track,
    /// which is what processing reads from the manifest.
    public static func change(
        _ metadata: MeetingMetadata, to range: TrimRange, archive: AudioArchive,
        cleanedMic: AudioArchive.Track?, at now: Date
    ) -> TrimMetadataChange {
        let kept = CaptureTrack.allCases.compactMap { archive.track($0)?.seconds }.max() ?? range.seconds
        let startedAt = metadata.startedAt.addingTimeInterval(range.start)
        return TrimMetadataChange(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(kept), durationSeconds: kept,
            audioArchive: archive, cleanedMicrophone: cleanedMic,
            dropsCleanedMicrophone: metadata.cleanedMic != nil && cleanedMic == nil, at: now
        )
    }
}
