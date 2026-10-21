import Foundation

/// Where diagnostics live: `~/Library/Logs/Pipit/`.
///
/// Outside the meetings folder, which a person copies, syncs and shares, and
/// away from the voice profiles in Application Support. The root is a
/// parameter so a test writes under a temporary directory.
public struct DiagnosticLayout: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Pipit", isDirectory: true)
    }

    public static var standard: DiagnosticLayout { DiagnosticLayout(root: defaultRoot) }

    /// Shared with the sandboxed Safari relay, which cannot write the app's log.
    public static func safariExtension(groupContainer: URL) -> DiagnosticLayout {
        DiagnosticLayout(root: groupContainer.appendingPathComponent("Diagnostics", isDirectory: true))
    }

    public var events: URL { root.appendingPathComponent("events", isDirectory: true) }
    public var state: URL { root.appendingPathComponent("state", isDirectory: true) }
    public var launchState: URL { state.appendingPathComponent("launch.json") }
    public var crashes: URL { root.appendingPathComponent("crashes", isDirectory: true) }
    public var outbox: URL { root.appendingPathComponent("outbox", isDirectory: true) }
    public var sentReceipts: URL { root.appendingPathComponent("sent.json") }

    /// A file of app events. Part 0 is `events-YYYY-MM-DD.ndjson`; when it
    /// reaches its size the day continues in `events-YYYY-MM-DD.1.ndjson`, then
    /// `.2`. A file is never renamed while another process could be reading
    /// it, and ordering by day, then part, is the order the lines were
    /// written in.
    public func eventsFile(day: String, part: Int) -> URL {
        events.appendingPathComponent(EventFile(family: .app, day: day, part: part).name)
    }

    /// The day's file of events from `pipit-nativehost`.
    public func nativeHostFile(day: String) -> URL {
        events.appendingPathComponent(EventFile(family: .nativeHost, day: day, part: 0).name)
    }

    /// The UTC day an event belongs to, `YYYY-MM-DD`.
    public static func day(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The start of a `YYYY-MM-DD` day in UTC, or nil for a name that is not one.
    static func date(ofDay day: String) -> Date? {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2])
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))
    }
}

/// The name of one events file, and what it says about itself.
public struct EventFile: Sendable, Equatable, Hashable {
    public enum Family: String, Sendable {
        /// `events-…`, written by the app.
        case app = "events"
        /// `nativehost-…`, written by the native messaging host.
        case nativeHost = "nativehost"
    }

    public let family: Family
    public let day: String
    public let part: Int

    public init(family: Family, day: String, part: Int) {
        self.family = family
        self.day = day
        self.part = part
    }

    public var name: String {
        part == 0 ? "\(family.rawValue)-\(day).ndjson" : "\(family.rawValue)-\(day).\(part).ndjson"
    }

    /// Nil for anything that is not an events file, so a stray file in the
    /// directory is neither counted nor deleted by the size policy.
    public init?(name: String) {
        guard name.hasSuffix(".ndjson") else { return nil }
        let stem = name.dropLast(".ndjson".count)
        let family: Family
        let rest: Substring
        if stem.hasPrefix("events-") {
            family = .app
            rest = stem.dropFirst("events-".count)
        } else if stem.hasPrefix("nativehost-") {
            family = .nativeHost
            rest = stem.dropFirst("nativehost-".count)
        } else {
            return nil
        }
        let pieces = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard let dayPart = pieces.first, DiagnosticLayout.date(ofDay: String(dayPart)) != nil,
            dayPart.count == 10
        else { return nil }
        var part = 0
        if pieces.count == 2 {
            guard let number = Int(pieces[1]), number > 0 else { return nil }
            part = number
        } else if pieces.count > 2 {
            return nil
        }
        self.init(family: family, day: String(dayPart), part: part)
    }
}
