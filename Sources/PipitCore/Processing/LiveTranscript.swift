import Foundation

/// One piece of text from a live engine for one track.
///
/// A provisional update is the engine's current guess at what is being said
/// and replaces the guess before it. A final update settles that text, and the
/// next update starts a new line. Times are seconds from the start of the
/// recording.
public struct LiveTextUpdate: Sendable, Equatable {
    public var text: String
    public var isFinal: Bool
    public var start: Double
    public var end: Double

    public init(text: String, isFinal: Bool, start: Double, end: Double) {
        self.text = text
        self.isFinal = isFinal
        self.start = start
        self.end = end
    }
}

/// One line of the live transcript.
public struct LiveTranscriptLine: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// Words heard on a track.
        case speech(CaptureTrack)
        /// A note the person typed during the call.
        case note
    }

    public let id: Int
    public var kind: Kind
    public var start: Double
    public var end: Double
    public var text: String
    /// False while the engine may still replace the words.
    public var isFinal: Bool

    public init(id: Int, kind: Kind, start: Double, end: Double, text: String, isFinal: Bool) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.text = text
        self.isFinal = isFinal
    }
}

/// Who spoke on the far-end track over a stretch of the recording, from a
/// speaker pass over the audio so far.
public struct LiveSpeakerTurn: Sendable, Equatable {
    public var start: Double
    public var end: Double
    /// Stable for the rest of the call once assigned, so a line keeps its
    /// label when a later pass reruns over more audio.
    public var speaker: String

    public init(start: Double, end: Double, speaker: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// The live transcript of one recording, as plain values.
///
/// Engines push updates per track; the speaker pass labels the far-end lines
/// afterwards. Nothing here is saved: the meeting's transcript is written by
/// the pass over the whole recording once it ends.
public struct LiveTranscript: Sendable, Equatable {
    public private(set) var lines: [LiveTranscriptLine] = []
    /// The far end's speaker turns from the latest speaker pass.
    public private(set) var turns: [LiveSpeakerTurn] = []
    /// Display names for speakers the voice memory recognised.
    public private(set) var names: [String: String] = [:]
    private var nextID = 0
    /// The provisional line each track is filling, if any.
    private var open: [CaptureTrack: Int] = [:]

    public init() {}

    /// Applies one engine update for `track`.
    public mutating func apply(_ update: LiveTextUpdate, track: CaptureTrack) {
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = open[track], let index = lines.firstIndex(where: { $0.id == id }) {
            if text.isEmpty, !update.isFinal {
                // An empty guess means the engine dropped what it had; the
                // line goes rather than sitting blank on screen.
                lines.remove(at: index)
                open[track] = nil
                return
            }
            if text.isEmpty {
                lines.remove(at: index)
            } else {
                lines[index].text = text
                lines[index].start = min(lines[index].start, update.start)
                lines[index].end = max(update.end, lines[index].start)
                lines[index].isFinal = update.isFinal
            }
            if update.isFinal { open[track] = nil }
            sortIfNeeded()
            return
        }
        guard !text.isEmpty else { return }
        let line = LiveTranscriptLine(
            id: takeID(), kind: .speech(track), start: update.start,
            end: max(update.end, update.start), text: text, isFinal: update.isFinal
        )
        lines.append(line)
        if !update.isFinal { open[track] = line.id }
        sortIfNeeded()
    }

    /// Adds a typed note at `time` seconds into the recording.
    public mutating func addNote(_ text: String, at time: Double) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append(
            LiveTranscriptLine(id: takeID(), kind: .note, start: time, end: time, text: trimmed, isFinal: true)
        )
        sortIfNeeded()
    }

    /// Replaces the far end's speaker turns and the names known for them.
    public mutating func label(turns: [LiveSpeakerTurn], names: [String: String]) {
        self.turns = turns.sorted { $0.start < $1.start }
        self.names = names
    }

    /// The far-end speaker who talked most over the line, or nil before a
    /// speaker pass has covered it.
    public func speaker(of line: LiveTranscriptLine) -> String? {
        guard line.kind == .speech(.remote) else { return nil }
        var overlap: [String: Double] = [:]
        for turn in turns where turn.end > line.start && turn.start < line.end {
            overlap[turn.speaker, default: 0] += min(turn.end, line.end) - max(turn.start, line.start)
        }
        if let best = overlap.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) {
            return best.key
        }
        // A line shorter than the gap between turns still belongs to whoever
        // spoke nearest to it, within a second.
        let middle = (line.start + line.end) / 2
        let nearest = turns.min { distance(middle, $0) < distance(middle, $1) }
        guard let nearest, distance(middle, nearest) <= 1 else { return nil }
        return nearest.speaker
    }

    /// The name to show for a far-end speaker: a recognised person's name, or
    /// a numbered label that stays the same for the whole call.
    public func displayName(ofSpeaker speaker: String) -> String {
        if let name = names[speaker] { return name }
        // Labels from `LiveSpeakerLabels` count up from 1 in the order the
        // speakers first spoke, and keep their number for the whole call.
        // Speaker 1 is the person recording, so the far end starts at 2.
        let number = Int(speaker.split(separator: "-").last ?? "") ?? 0
        return "Speaker \(number + 1)"
    }

    /// Whether a far-end line says `name` as a word, which is how the window
    /// tells the person they were mentioned.
    public static func mentions(_ name: String, in text: String) -> Bool {
        let first = name.split(separator: " ").first.map(String.init) ?? ""
        guard first.count >= 2 else { return false }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: first) + "\\b"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func distance(_ time: Double, _ turn: LiveSpeakerTurn) -> Double {
        if time < turn.start { return turn.start - time }
        if time > turn.end { return time - turn.end }
        return 0
    }

    private mutating func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    /// Lines stay in the order they were spoken across both tracks. Updates
    /// arrive almost in order, so this is usually a no-op check.
    private mutating func sortIfNeeded() {
        guard zip(lines, lines.dropFirst()).contains(where: { $0.start > $1.start }) else { return }
        lines.sort { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
}
