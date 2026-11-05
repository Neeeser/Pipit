import Foundation

/// One note the person wrote about a meeting, as the timeline shows it.
///
/// A note added while the meeting records is saved in `notes.md` as
/// `- [<UTC time>] text`, so it can be placed at the moment it was typed.
/// Anything else in the file was written afterwards and has no moment.
public struct MeetingNoteEntry: Sendable, Equatable {
    public var text: String
    /// Seconds into the meeting, or nil for a note written without a time.
    public var at: Double?

    public init(text: String, at: Double? = nil) {
        self.text = text
        self.at = at
    }

    /// Every note in `notes.md`, one per non-empty line, in file order.
    public static func entries(in notes: String, startedAt: Date) -> [MeetingNoteEntry] {
        notes.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("* ") { line = String(line.dropFirst(2)) }
            if line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                let date = ManifestCoding.date(from: String(line[line.index(after: line.startIndex)..<close]))
            {
                let text = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                // A note typed in the moments before the recording started
                // belongs at its start.
                return MeetingNoteEntry(text: text, at: max(0, date.timeIntervalSince(startedAt)))
            }
            let text = line.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : MeetingNoteEntry(text: text)
        }
    }
}
