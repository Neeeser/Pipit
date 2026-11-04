import Foundation
import Observation
import PipitCore

/// What the live window shows: the transcript of the recording in progress,
/// or of the last one until the next starts.
@MainActor
@Observable
public final class LiveTranscriptModel {
    public enum State: Sendable, Equatable {
        /// No recording has run since launch.
        case idle
        /// Loading the engine.
        case starting
        case live
        /// The recording ended; the lines stay until the next one starts.
        case ended
        /// Live text is off in Settings.
        case off
        /// The chosen engine cannot run here, with a reason for the person.
        case unavailable(String)
    }

    public private(set) var state: State = .idle
    public private(set) var transcript = LiveTranscript()
    public private(set) var meetingTitle = ""
    /// The meeting being recorded, for opening it once the call ends.
    public private(set) var meetingID: String?
    /// Seconds of audio heard so far in this recording.
    public private(set) var elapsed: Double = 0
    /// The line that last said the person's name, while it is recent.
    public private(set) var mention: LiveTranscriptLine?
    /// The person's own name, for their lines and for spotting mentions.
    public var localUserName = ""
    /// Whether the window is kept out of screen shares, for its badge.
    public var hiddenFromSharing = true
    /// Saves a typed note with the meeting. Set by the runtime.
    @ObservationIgnored public var saveNote: ((String) -> Void)?
    /// Sees every engine update as it lands, for the replay harness to time.
    @ObservationIgnored public var onUpdate: ((LiveTextUpdate, CaptureTrack) -> Void)?
    /// Asks the window layer to show the live window.
    @ObservationIgnored public var onOpenRequest: (() -> Void)?

    public init() {}

    func begin(title: String, meetingID: String) {
        transcript = LiveTranscript()
        meetingTitle = title
        self.meetingID = meetingID
        elapsed = 0
        mention = nil
        state = .starting
    }

    func setState(_ state: State) { self.state = state }

    func retitle(_ title: String) { meetingTitle = title }

    func apply(_ update: LiveTextUpdate, track: CaptureTrack) {
        onUpdate?(update, track)
        transcript.apply(update, track: track)
        guard track == .remote, update.isFinal, !localUserName.isEmpty, localUserName != "Me",
            LiveTranscript.mentions(localUserName, in: update.text),
            let line = transcript.lines.last(where: { $0.kind == .speech(.remote) && $0.text == update.text })
        else { return }
        mention = line
    }

    func label(turns: [LiveSpeakerTurn], names: [String: String]) {
        transcript.label(turns: turns, names: names)
    }

    func advance(to seconds: Double) {
        guard seconds > elapsed else { return }
        elapsed = seconds
        // A mention stays highlighted for half a minute.
        if let mention, seconds - mention.end > 30 { self.mention = nil }
    }

    /// Adds a note typed in the window, to the live transcript and to the
    /// meeting's notes.
    public func addNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcript.addNote(trimmed, at: elapsed)
        saveNote?(trimmed)
    }

    public func dismissMention() { mention = nil }

    /// The label for a line's speaker.
    public func speakerName(of line: LiveTranscriptLine) -> String {
        switch line.kind {
        case .note: return "Note"
        case .speech(.mic):
            // The name the saved transcript uses for the person recording.
            let name = localUserName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Me" : name
        case .speech(.remote):
            // Grey until a speaker pass covers the line, then a number or a
            // recognised name.
            guard let speaker = transcript.speaker(of: line) else { return "Speaker" }
            return transcript.displayName(ofSpeaker: speaker)
        }
    }

    /// A stable key for a line's speaker, for colouring.
    public func speakerKey(of line: LiveTranscriptLine) -> String {
        switch line.kind {
        case .note: return "note"
        case .speech(.mic): return "you"
        case .speech(.remote): return transcript.speaker(of: line) ?? "others"
        }
    }
}
