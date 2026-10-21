import Foundation

/// Merges identical events that arrive within a window into one line.
///
/// A capture fault can raise the same event twice a second for as long as it
/// lasts, which would fill the 10 MB cap in an afternoon and push out the
/// events that explain it. The first event of a burst is written at once, so a
/// crash a moment later still leaves it on disk. The repeats are counted and
/// written as one line carrying `n` when the window closes, stamped with the
/// last repeat's time. Identical means the same kind, payload, session and job.
struct DiagnosticCoalescer {
    private struct Key: Hashable {
        let kind: DiagnosticEvent.Kind
        let session: DiagnosticSessionID?
        let job: DiagnosticJobID?
    }

    private struct Window {
        let opened: Date
        var latest: DiagnosticEvent
        var repeats: Int
    }

    let window: TimeInterval
    /// Open windows beyond this are closed early, oldest first, so a stream
    /// of distinct events cannot grow the table without bound.
    let capacity: Int
    private var windows: [Key: Window] = [:]

    init(window: TimeInterval = 60, capacity: Int = 256) {
        self.window = window
        self.capacity = capacity
    }

    /// The lines to write for one event: any windows it closed, then the event
    /// itself if it opened a new one.
    mutating func admit(_ event: DiagnosticEvent) -> [DiagnosticEvent] {
        var lines = expire(at: event.time)
        let key = Key(kind: event.kind, session: event.session, job: event.job)
        if var open = windows[key] {
            open.repeats += event.count
            open.latest = event
            windows[key] = open
            return lines
        }
        if windows.count >= capacity { lines += closeOldest() }
        windows[key] = Window(opened: event.time, latest: event, repeats: 0)
        lines.append(event)
        return lines
    }

    /// Closes every window opened `window` seconds or more before `now`.
    mutating func expire(at now: Date) -> [DiagnosticEvent] {
        let closing = windows.filter { now.timeIntervalSince($0.value.opened) >= window }
        for key in closing.keys { windows.removeValue(forKey: key) }
        return closing.values.sorted { $0.opened < $1.opened }.compactMap(Self.line(for:))
    }

    /// Closes every window, for a flush at exit or before the files are cleared.
    mutating func closeAll() -> [DiagnosticEvent] {
        let closing = windows.values.sorted { $0.opened < $1.opened }
        windows = [:]
        return closing.compactMap(Self.line(for:))
    }

    /// Forgets every window without writing it, for a clear.
    mutating func reset() { windows = [:] }

    /// When the earliest open window that holds repeats closes, which is when
    /// the recorder has to come back to write it.
    var nextDeadline: Date? {
        windows.values.filter { $0.repeats > 0 }.map { $0.opened.addingTimeInterval(window) }.min()
    }

    private mutating func closeOldest() -> [DiagnosticEvent] {
        guard let oldest = windows.min(by: { $0.value.opened < $1.value.opened }) else { return [] }
        windows.removeValue(forKey: oldest.key)
        return Self.line(for: oldest.value).map { [$0] } ?? []
    }

    private static func line(for window: Window) -> DiagnosticEvent? {
        guard window.repeats > 0 else { return nil }
        var line = window.latest
        line.count = window.repeats
        return line
    }
}
