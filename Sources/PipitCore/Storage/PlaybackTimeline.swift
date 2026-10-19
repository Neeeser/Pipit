import Foundation

/// The conversation's audio as one thing to play: each recording's
/// `recording.m4a`, back to back, earliest first.
///
/// A position on this timeline is playback seconds. The gap between a dropped
/// call and its rejoin is on no recording, so it is not on this timeline
/// either, and the parts sit end to end. What the player prints is the
/// conversation's own clock instead, the one the transcript headers read, so a
/// time on the bar and a time over a turn agree.
///
/// Each mixdown is aligned to the timeline its recording's transcript is on,
/// so a word's own seconds are a moment in that recording's file.
public struct PlaybackTimeline: Sendable, Equatable {
    /// One recording's audio file and where it sits.
    public struct Part: Sendable, Equatable {
        public var recordingID: String
        public var audio: URL
        /// Where this part begins, in playback seconds.
        public var start: Double
        public var duration: Double
        /// Where this recording began on the conversation's clock, which is the
        /// axis `CombinedLine.timelineStart` is on.
        public var timelineOffset: Double

        public var end: Double { start + duration }
    }

    /// What a recording contributes before the parts are laid end to end.
    public struct Source: Sendable, Equatable {
        public var recordingID: String
        public var audio: URL
        public var duration: Double
        public var timelineOffset: Double

        public init(recordingID: String, audio: URL, duration: Double, timelineOffset: Double) {
            self.recordingID = recordingID
            self.audio = audio
            self.duration = duration
            self.timelineOffset = timelineOffset
        }
    }

    public private(set) var parts: [Part]

    /// Lays the sources end to end in the order given. A source with no audio
    /// in it takes no room.
    public init(_ sources: [Source] = []) {
        var parts: [Part] = []
        var start = 0.0
        for source in sources where source.duration > 0 {
            parts.append(
                Part(
                    recordingID: source.recordingID, audio: source.audio, start: start,
                    duration: source.duration, timelineOffset: source.timelineOffset
                ))
            start += source.duration
        }
        self.parts = parts
    }

    public var isEmpty: Bool { parts.isEmpty }

    /// Seconds of audio, summed over the parts.
    public var duration: Double { parts.last?.end ?? 0 }

    /// Where the second part and every later one begins, for the marks
    /// between them.
    public var boundaries: [Double] { parts.dropFirst().map(\.start) }

    /// The part a position falls in and the seconds into its file. A position
    /// on a boundary belongs to the part that starts there; one past the end
    /// lands on the last moment of the last part.
    public func locate(_ position: Double) -> (part: Int, seconds: Double)? {
        guard !parts.isEmpty else { return nil }
        let clamped = min(max(position, 0), duration)
        let index = parts.lastIndex { $0.start <= clamped } ?? 0
        let part = parts[index]
        return (index, min(clamped - part.start, part.duration))
    }

    /// The playback position of a moment in one recording, or nil when that
    /// recording has no audio to play.
    public func position(recordingID: String, seconds: Double) -> Double? {
        guard let part = parts.first(where: { $0.recordingID == recordingID }) else { return nil }
        return part.start + min(max(seconds, 0), part.duration)
    }

    /// The conversation's clock at a playback position.
    public func timelineSeconds(at position: Double) -> Double {
        guard let located = locate(position) else { return 0 }
        return parts[located.part].timelineOffset + located.seconds
    }

    /// The conversation's clock at the end of the last part.
    public var timelineDuration: Double {
        guard let last = parts.last else { return 0 }
        return last.timelineOffset + last.duration
    }
}

/// When one speaker talks, as stretches of playback.
public struct SpeakerLane: Sendable, Equatable, Identifiable {
    public struct Span: Sendable, Equatable {
        public var start: Double
        public var end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    public var name: String
    /// In time order, with stretches that touch or nearly touch merged.
    public var spans: [Span]

    public var id: String { name }

    public init(name: String, spans: [Span]) {
        self.name = name
        self.spans = spans
    }
}

/// Where playback is in the transcript.
public struct PlaybackCursor: Sendable, Equatable {
    /// The turn being played, or the last one started when playback sits in a
    /// pause between turns.
    public var blockID: String
    public var speakerName: String
    public var recordingID: String
    /// Whether the position is inside one of the turn's lines rather than in
    /// the silence after it.
    public var isSpeaking: Bool
    /// The word under the position, where the line has word timings.
    public var word: TranscriptWordSpan?

    public init(
        blockID: String, speakerName: String, recordingID: String, isSpeaking: Bool,
        word: TranscriptWordSpan?
    ) {
        self.blockID = blockID
        self.speakerName = speakerName
        self.recordingID = recordingID
        self.isSpeaking = isSpeaking
        self.word = word
    }
}

extension PlaybackTimeline {
    /// Two stretches of one speaker closer than this draw as one, so a lane
    /// reads as turns rather than as every breath between lines.
    static let laneMergeGap: Double = 0.75

    /// One lane per speaker, in the order given, then anyone the order left
    /// out in the order they first speak.
    ///
    /// Keyed by the name the transcript prints, because the lane is read
    /// against the names over the turns. Lines from a recording with no audio
    /// are left off: there is nothing to play there.
    public func lanes(for lines: [CombinedLine], order: [String] = []) -> [SpeakerLane] {
        var spans: [String: [SpeakerLane.Span]] = [:]
        var firstHeard: [String] = []
        for line in lines {
            guard
                let start = position(recordingID: line.recordingID, seconds: line.utterance.start),
                let end = position(recordingID: line.recordingID, seconds: line.utterance.end),
                end > start
            else { continue }
            if spans[line.speakerName] == nil { firstHeard.append(line.speakerName) }
            spans[line.speakerName, default: []].append(.init(start: start, end: end))
        }
        var names: [String] = []
        for name in order + firstHeard where spans[name] != nil && !names.contains(name) {
            names.append(name)
        }
        return names.map { name in
            SpeakerLane(name: name, spans: Self.merged(spans[name] ?? []))
        }
    }

    static func merged(_ spans: [SpeakerLane.Span]) -> [SpeakerLane.Span] {
        var out: [SpeakerLane.Span] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, span.start <= last.end + laneMergeGap {
                out[out.count - 1].end = max(last.end, span.end)
            } else {
                out.append(span)
            }
        }
        return out
    }

    /// The turn and word at a playback position.
    ///
    /// The turn is the one whose lines hold the moment, or else the last turn
    /// of that recording that had started by then, so the band stays on the
    /// turn just heard through the pause before the next. Where the microphone
    /// and the far end overlap, the turn printed first wins, which is the one
    /// the reader's eye is already on.
    public func cursor(at position: Double, in blocks: [CombinedLineBlock]) -> PlaybackCursor? {
        guard let located = locate(position) else { return nil }
        let seconds = located.seconds
        let recordingID = parts[located.part].recordingID
        let inRecording = blocks.filter { $0.recordingID == recordingID }
        let speaking = inRecording.first { block in
            block.lines.contains { $0.utterance.start <= seconds && seconds < $0.utterance.end }
        }
        let started = inRecording.last { block in
            block.lines.contains { $0.utterance.start <= seconds }
        }
        guard let block = speaking ?? started else { return nil }
        return PlaybackCursor(
            blockID: block.id,
            speakerName: block.speakerName,
            recordingID: recordingID,
            isSpeaking: speaking != nil,
            word: speaking == nil ? nil : Self.word(at: seconds, in: block)
        )
    }

    /// The word being spoken, or nil where the line has no word timings and
    /// the paragraph only knows where the whole line begins and ends.
    static func word(at seconds: Double, in block: CombinedLineBlock) -> TranscriptWordSpan? {
        let spans = block.paragraph().spans
        guard
            let line = block.lines.first(where: {
                $0.utterance.start <= seconds && seconds < $0.utterance.end
            })
        else { return nil }
        let lineSpans = spans.filter { $0.utteranceID == line.utterance.id }
        // One span for a line is the whole line, unless the line really is a
        // single timed word.
        if lineSpans.count == 1, line.utterance.words?.count != 1 { return nil }
        return lineSpans.last { $0.startSeconds <= seconds }
    }
}
