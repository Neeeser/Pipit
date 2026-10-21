import Foundation
import PipitCore

/// The last launch as `pipit diagnostics crashes` reports it: what
/// `state/launch.json` says, and how that launch ended.
public struct LaunchEntry: Codable, Sendable, Equatable {
    public var launch: String
    public var pid: Int32
    public var startedAt: Date
    public var version: String
    public var binaryUUID: String?
    /// The launch is still running, so it has not ended yet and `exit` is nil.
    public var running: Bool
    public var exit: ExitClass?
    /// The crash report that decided `exit`, for `crash` and `hang`.
    public var incident: String?
}

public struct CrashListing: Codable, Sendable, Equatable {
    public var schemaVersion = MeetingReport.schemaVersion
    public var reportsDirectory: String
    public var lastLaunch: LaunchEntry?
    /// Pipit's crashes from the last 90 days, newest first: the summaries kept
    /// in `crashes/` and any report the app has not read yet.
    public var crashes: [CrashRecord]
}

/// Reads the crash reports and the launch record. Nothing here writes: the
/// app keeps `crashes/` and `state/`, and the command only reports on them.
struct CrashDiagnostics {
    let home: URL
    let bootSession: String?

    func listing(now: Date = Date()) -> CrashListing {
        let scanner = CrashReportScanner(home: home)
        let since = now.addingTimeInterval(-CrashReportScanner.maximumAge)
        var seen = Set<String>()
        let crashes = (scanner.scan(since: since) + scanner.stored())
            .filter { seen.insert($0.incident).inserted }
            .sorted { $0.summary.occurredAt > $1.summary.occurredAt }
        let record = LaunchRecordStore(directory: LaunchRecordStore.defaultDirectory(home: home)).load()
        return CrashListing(
            reportsDirectory: scanner.reportsDirectory.path,
            lastLaunch: record.map { entry(for: $0, crashes: crashes) },
            crashes: crashes
        )
    }

    private func entry(for record: LaunchRecord, crashes: [CrashRecord]) -> LaunchEntry {
        let classification = ExitClassifier.classify(
            previous: record, currentBootSession: bootSession, reports: crashes
        )
        let ended = classification.map { [.clean, .crash, .hang, .systemRestart].contains($0.exitClass) } ?? false
        let running = !ended && isRunning(record)
        return LaunchEntry(
            launch: record.launch, pid: record.pid, startedAt: record.startedAt, version: record.version,
            binaryUUID: record.binaryUUID, running: running,
            exit: running ? nil : classification?.exitClass, incident: running ? nil : classification?.incident
        )
    }

    /// Whether the recorded process is still alive in this boot. A pid can be
    /// reused once the process is gone, so this can mistake another process
    /// for Pipit; it never mistakes a running Pipit for an ended one.
    private func isRunning(_ record: LaunchRecord) -> Bool {
        guard record.pid > 0 else { return false }
        if let before = record.bootSession, let now = bootSession, before != now { return false }
        return kill(record.pid, 0) == 0 || errno == EPERM
    }
}
