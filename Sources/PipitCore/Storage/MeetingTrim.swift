import Foundation

/// The stretch of a recording a person chose to keep, in seconds on the
/// meeting's timeline.
public struct TrimRange: Sendable, Equatable {
    public let start: Double
    public let end: Double

    /// Nil when the range keeps nothing or keeps everything: a trim has to
    /// remove something and leave something.
    public init?(start: Double, end: Double, duration: Double) {
        let start = max(0, start)
        let end = min(duration, end)
        guard end - start >= MeetingTrim.shortestKept else { return nil }
        guard start > MeetingTrim.tolerance || duration - end > MeetingTrim.tolerance else { return nil }
        self.start = start
        self.end = end
    }

    public var seconds: Double { end - start }

    /// Where a time on the old timeline lands on the trimmed one, or nil when
    /// it was cut.
    public func moved(_ time: Double) -> Double? {
        guard time >= start, time < end else { return nil }
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
        let clippedEnd = min(end, range.end)
        guard clippedEnd > clippedStart else { return nil }
        return (clippedStart - range.start, clippedEnd - range.start)
    }

    public static func trim(_ transcript: RawTranscript, to range: TrimRange) -> RawTranscript {
        var trimmed = transcript
        trimmed.chunks = transcript.chunks.compactMap { trim($0, to: range) }
        return trimmed
    }

    static func trim(_ chunk: RawTranscriptChunk, to range: TrimRange) -> RawTranscriptChunk? {
        let offset = chunk.timelineOffset
        guard let span = clip(start: offset, end: offset + chunk.durationSeconds, to: range) else { return nil }
        var trimmed = chunk
        trimmed.timelineOffset = span.start
        trimmed.durationSeconds = span.end - span.start
        // A position inside the chunk, measured from its old start, measured
        // again from its new one.
        let shift = offset - range.start - span.start
        trimmed.segments = chunk.segments.compactMap { segment in
            guard
                let kept = clip(start: offset + segment.start, end: offset + segment.end, to: range)
            else { return nil }
            var moved = segment
            moved.start = kept.start - span.start
            moved.end = kept.end - span.start
            if let words = segment.words {
                let keptWords = words.compactMap { word -> RawTranscriptWord? in
                    guard range.moved(offset + word.start) != nil else { return nil }
                    var movedWord = word
                    movedWord.start = word.start + shift
                    movedWord.end = min(word.end + shift, moved.end)
                    return movedWord
                }
                if keptWords.isEmpty { return nil }
                if keptWords.count != words.count {
                    moved.text = keptWords.map(\.text).joined()
                }
                moved.words = keptWords
            }
            return moved
        }
        return trimmed
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
            guard let anchor = range.moved(override.anchorSeconds) else { return nil }
            var moved = override
            moved.anchorSeconds = anchor
            moved.startSeconds = override.startSeconds.map { max(0, $0 - range.start) }
            moved.endSeconds = override.endSeconds.map { min(range.seconds, $0 - range.start) }
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
        let last = min(values.count, Int((range.end / width).rounded(.up)))
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

    /// The part of one archived track that the range keeps.
    public static func cut(
        _ track: AudioArchive.Track, origin: Double?, range: TrimRange
    ) -> TrackCut? {
        let lead = origin.flatMap { origin in track.firstFrameHostTime.map { $0 - origin } } ?? 0
        let from = max(0, range.start - lead)
        let to = min(track.seconds, range.end - lead)
        guard to > from else { return nil }
        return TrackCut(from: from, to: to)
    }

    /// The archive record for a track whose file now holds only `cut`.
    public static func trimmed(
        _ track: AudioArchive.Track, cut: TrackCut, frameCount: Int64
    ) -> AudioArchive.Track {
        var moved = track
        moved.frameCount = frameCount
        moved.seconds = Double(frameCount) / track.sampleRate
        moved.firstFrameHostTime = track.firstFrameHostTime.map { $0 + cut.from }
        return moved
    }

    // MARK: metadata

    /// The meeting's own record after the trim, given the archive records the
    /// rewritten audio files produced. Processing goes back to enrichment, so
    /// the summary and title are written again from what is left.
    public static func trim(
        _ metadata: MeetingMetadata, to range: TrimRange, archive: AudioArchive,
        cleanedMic: AudioArchive.Track?, at now: Date
    ) -> MeetingMetadata {
        var trimmed = metadata
        let startedAt = metadata.startedAt.addingTimeInterval(range.start)
        let endedAt = metadata.startedAt.addingTimeInterval(range.end)
        trimmed.startedAt = startedAt
        trimmed.endedAt = endedAt
        trimmed.durationSeconds = range.seconds
        trimmed.runs = metadata.runs.map { run in
            var moved = run
            moved.startedAt = startedAt
            moved.endedAt = endedAt
            moved.durationSeconds = range.seconds
            return moved
        }
        trimmed.audioArchive = archive
        if let cleanedMic, var cleaned = metadata.cleanedMic {
            cleaned.track = cleanedMic
            trimmed.cleanedMic = cleaned
        }
        trimmed.processing.state = .enriching
        trimmed.processing.updatedAt = now
        trimmed.processing.completedStages.removeAll { $0 == .enriching || $0 == .complete }
        trimmed.processing.lastFailure = nil
        trimmed.processing.failedStage = nil
        return trimmed
    }

    // MARK: manifest

    /// The capture record cut to the range. Segments are clipped to the audio
    /// that is left, their frame positions restart at zero, and every other
    /// event outside the range is dropped, except the device and stream
    /// descriptions from before the cut, which are moved to its start because
    /// they still describe the audio that remains.
    public static func trim(
        _ lines: [ManifestLine], to range: TrimRange, origin: Double, keptSeconds: [CaptureTrack: Double]
    ) -> [ManifestLine] {
        let startHost = origin + range.start
        let endHost = origin + range.end
        let (openings, closings) = segmentEvents(lines)
        var output: [ManifestLine] = []
        var keptSegments: Set<SegmentKey> = []
        var sessionStartWall: Date?
        for line in lines {
            switch line.event {
            case .sessionStart:
                sessionStartWall = line.wallClock.addingTimeInterval(range.start)
                output.append(
                    ManifestLine(
                        hostTime: max(line.hostTime, startHost), wallClock: sessionStartWall ?? line.wallClock,
                        event: line.event
                    ))
            case .segmentOpen(let open):
                let key = SegmentKey(track: open.track, index: open.index)
                guard let moved = clip(open, close: closings[key], startHost: startHost, endHost: endHost, line: line)
                else { continue }
                keptSegments.insert(key)
                output.append(moved)
            case .segmentClose(let close):
                let key = SegmentKey(track: close.track, index: close.index)
                guard keptSegments.contains(key), let open = openings[key] else { continue }
                output.append(clip(close, open: open, startHost: startHost, endHost: endHost, line: line))
            case .crashTailAdopted(let adopted):
                guard keptSegments.contains(SegmentKey(track: adopted.track, index: adopted.index)) else { continue }
                output.append(line)
            case .sessionEnd(let end):
                let wall = (sessionStartWall ?? line.wallClock).addingTimeInterval(range.seconds)
                output.append(
                    ManifestLine(
                        hostTime: min(line.hostTime, endHost), wallClock: wall,
                        event: .sessionEnd(
                            ManifestEvent.SessionEnd(
                                reason: end.reason,
                                micSeconds: keptSeconds[.mic] ?? 0,
                                remoteSeconds: keptSeconds[.remote] ?? 0
                            ))
                    ))
            case .micBind, .remoteBind, .remoteStream, .sourceHealth, .formatChange:
                if let moved = moveDescription(line, startHost: startHost, endHost: endHost) { output.append(moved) }
            default:
                guard line.hostTime >= startHost, line.hostTime <= endHost else { continue }
                output.append(line)
            }
        }
        // Each track's frames restart at zero after the cut.
        return renumberStartFrames(output, startHost: startHost)
    }

    struct SegmentKey: Hashable {
        let track: CaptureTrack
        let index: Int
    }

    /// Every segment's opening and closing, by track and index.
    private static func segmentEvents(
        _ lines: [ManifestLine]
    ) -> ([SegmentKey: ManifestEvent.SegmentOpen], [SegmentKey: ManifestEvent.SegmentClose]) {
        var openings: [SegmentKey: ManifestEvent.SegmentOpen] = [:]
        var closings: [SegmentKey: ManifestEvent.SegmentClose] = [:]
        for line in lines {
            switch line.event {
            case .segmentOpen(let open): openings[SegmentKey(track: open.track, index: open.index)] = open
            case .segmentClose(let close): closings[SegmentKey(track: close.track, index: close.index)] = close
            default: break
            }
        }
        return (openings, closings)
    }

    /// A segment that overlaps the range, starting where its kept audio
    /// starts. Nil for one wholly outside it.
    private static func clip(
        _ open: ManifestEvent.SegmentOpen, close: ManifestEvent.SegmentClose?,
        startHost: Double, endHost: Double, line: ManifestLine
    ) -> ManifestLine? {
        let span = hostSpan(open: open, close: close)
        if let span, span.end <= startHost || span.start >= endHost { return nil }
        let moved = ManifestEvent.SegmentOpen(
            track: open.track, index: open.index, file: open.file,
            firstFrameHostTime: span.map { max($0.start, startHost) } ?? open.firstFrameHostTime,
            startFrame: open.startFrame, sampleRate: open.sampleRate, channelCount: open.channelCount,
            reason: open.reason
        )
        return ManifestLine(
            hostTime: max(line.hostTime, startHost), wallClock: line.wallClock, event: .segmentOpen(moved))
    }

    /// A device or stream description. One from before the cut still
    /// describes the audio that remains, so it moves to the cut; one from
    /// after the range describes nothing kept.
    private static func moveDescription(_ line: ManifestLine, startHost: Double, endHost: Double) -> ManifestLine? {
        if line.hostTime > endHost { return nil }
        guard line.hostTime < startHost else { return line }
        return ManifestLine(
            hostTime: startHost, wallClock: line.wallClock.addingTimeInterval(startHost - line.hostTime),
            event: line.event
        )
    }

    /// The segment's span in host time. The first frame's host time is often
    /// known only when the segment closes, so either event may carry it.
    private static func hostSpan(
        open: ManifestEvent.SegmentOpen, close: ManifestEvent.SegmentClose?
    ) -> (start: Double, end: Double)? {
        guard let first = open.firstFrameHostTime ?? close?.firstFrameHostTime else { return nil }
        return (first, first + (close?.seconds ?? .infinity))
    }

    private static func clip(
        _ close: ManifestEvent.SegmentClose, open: ManifestEvent.SegmentOpen,
        startHost: Double, endHost: Double, line: ManifestLine
    ) -> ManifestLine {
        guard let span = hostSpan(open: open, close: close) else { return line }
        let keptStart = max(span.start, startHost)
        let keptEnd = min(span.end, endHost)
        if keptStart <= span.start, keptEnd >= span.end { return line }
        let seconds = max(0, keptEnd - keptStart)
        let rate = open.sampleRate > 0 ? open.sampleRate : 16_000
        let frames = Int64((seconds * rate).rounded())
        let bytes = close.seconds > 0 ? Int64(Double(close.byteCount) * seconds / close.seconds) : 0
        return ManifestLine(
            hostTime: min(line.hostTime, endHost), wallClock: line.wallClock,
            event: .segmentClose(
                ManifestEvent.SegmentClose(
                    track: close.track, index: close.index, frameCount: frames, byteCount: bytes,
                    seconds: seconds, firstFrameHostTime: keptStart, reason: "trimmed"
                ))
        )
    }

    /// Restarts each track's segment frame positions at zero, in order, from
    /// the clipped lengths.
    private static func renumberStartFrames(_ lines: [ManifestLine], startHost: Double) -> [ManifestLine] {
        var closes: [SegmentKey: ManifestEvent.SegmentClose] = [:]
        for line in lines {
            if case .segmentClose(let close) = line.event {
                closes[SegmentKey(track: close.track, index: close.index)] = close
            }
        }
        var position: [CaptureTrack: Int64] = [:]
        return lines.map { line in
            guard case .segmentOpen(let open) = line.event else { return line }
            let start = position[open.track] ?? 0
            if let close = closes[SegmentKey(track: open.track, index: open.index)] {
                position[open.track] = start + close.frameCount
            }
            let moved = ManifestEvent.SegmentOpen(
                track: open.track, index: open.index, file: open.file,
                firstFrameHostTime: open.firstFrameHostTime, startFrame: start,
                sampleRate: open.sampleRate, channelCount: open.channelCount, reason: open.reason
            )
            return ManifestLine(hostTime: line.hostTime, wallClock: line.wallClock, event: .segmentOpen(moved))
        }
    }
}
