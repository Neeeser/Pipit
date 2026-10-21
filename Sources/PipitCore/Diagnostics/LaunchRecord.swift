import Foundation

/// What `state/launch.json` says about one launch of Pipit
/// (`docs/DIAGNOSTICS.md`, Exit classes).
///
/// Written at launch with `clean` false and rewritten with `clean` true on a
/// clean exit. The next launch reads it before writing its own, and a record
/// still saying false is a launch that ended some other way. Every value is a
/// random identifier, a number, a time, or a version, so the file is safe to
/// carry into a report.
public struct LaunchRecord: Codable, Sendable, Equatable {
    /// The random UUID of this launch, the `launch` of its event lines.
    public var launch: String
    public var pid: Int32
    /// When the process started, UTC. The kernel's start time where it can be
    /// read, because that is what a crash report's `procLaunch` gives.
    public var startedAt: Date
    /// `kern.bootsessionuuid`, new at every boot.
    public var bootSession: String?
    /// The LC_UUID of the main executable, lowercase.
    public var binaryUUID: String?
    public var version: String
    public var clean: Bool

    public init(
        launch: String, pid: Int32, startedAt: Date, bootSession: String?, binaryUUID: String?, version: String,
        clean: Bool = false
    ) {
        self.launch = launch
        self.pid = pid
        self.startedAt = startedAt
        self.bootSession = bootSession
        self.binaryUUID = binaryUUID
        self.version = version
        self.clean = clean
    }
}

/// Reads and writes `state/launch.json`. The directory is injected, so tests
/// and the command line read a scratch or a real `state/` folder alike.
public struct LaunchRecordStore: Sendable {
    public static let fileName = "launch.json"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Logs/Pipit/state` under `home`.
    public static func defaultDirectory(home: URL) -> URL {
        home.appendingPathComponent("Library/Logs/Pipit/state", isDirectory: true)
    }

    public var file: URL { directory.appendingPathComponent(Self.fileName) }

    /// The record on disk, or nil when there is none or it cannot be read. A
    /// damaged record is the same as a missing one: the previous exit is then
    /// not classified, which is better than classifying it from a guess.
    public func load() -> LaunchRecord? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? DiagnosticCoding.makeDecoder().decode(LaunchRecord.self, from: data)
    }

    /// Replaces the record atomically, so a crash mid-write leaves the
    /// previous record or the new one, never half of either.
    public func save(_ record: LaunchRecord) throws {
        try AtomicFile.write(try DiagnosticCoding.makeFileEncoder().encode(record), to: file)
    }

    /// Writes the record of a launch that is starting and returns the one it
    /// replaced, which describes the launch before it.
    public func begin(_ record: LaunchRecord) throws -> LaunchRecord? {
        let previous = load()
        try save(record)
        return previous
    }

    /// Marks the launch `launch` as having exited cleanly. Does nothing when
    /// the file holds another launch's record, so a quitting copy never marks
    /// a newer one clean.
    public func markClean(launch: String) throws {
        guard var record = load(), record.launch == launch, !record.clean else { return }
        record.clean = true
        try save(record)
    }
}
