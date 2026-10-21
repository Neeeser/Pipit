import Foundation
import PipitCore

/// Tells at launch how the previous launch ended, and marks this one clean
/// at quit (`docs/DIAGNOSTICS.md`, Exit classes).
///
/// It writes `state/launch.json`, reads Pipit's crash reports from
/// `~/Library/Logs/DiagnosticReports`, keeps their reduced summaries in
/// `crashes/`, and records `app.previous_exit`. All of it is best effort: a
/// file that cannot be read or written leaves the previous exit
/// unclassified, and nothing reaches the person.
struct LaunchDiagnostics: Sendable {
    let launchRecords: LaunchRecordStore
    let scanner: CrashReportScanner

    init(layout: DiagnosticLayout, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        launchRecords = LaunchRecordStore(directory: layout.state)
        scanner = CrashReportScanner(
            reportsDirectory: CrashReportScanner(home: home).reportsDirectory,
            crashesDirectory: layout.crashes
        )
    }

    /// This launch's record. The start time is the kernel's, which is what a
    /// crash report gives as `procLaunch`; the clock is the fallback.
    static func record(launch: DiagnosticLaunchID, version: String, now: Date) -> LaunchRecord {
        LaunchRecord(
            launch: launch.uuid.uuidString.lowercased(),
            pid: getpid(),
            startedAt: ProcessIdentity.startTime() ?? now,
            bootSession: ProcessIdentity.bootSessionUUID(),
            binaryUUID: ProcessIdentity.mainBinaryUUID(),
            version: version
        )
    }

    /// Writes this launch's record, classifies the one it replaced, and
    /// records the answer. Then, when the previous exit had no report yet,
    /// looks again after `ExitClassifier.rescanDelay`, because ReportCrash can
    /// finish writing after Pipit has relaunched, and records the upgrade.
    func begin(_ record: LaunchRecord, diagnostics: DiagnosticLog, now: @Sendable () -> Date) async {
        guard let previous = try? launchRecords.begin(record) else { return }
        let window = previous.startedAt.addingTimeInterval(-ExitClassifier.launchLeadTolerance)
        let found = scanner.scan(since: window)
        scanner.store(found, now: now())
        guard
            let classification = ExitClassifier.classify(
                previous: previous, currentBootSession: record.bootSession, reports: found
            )
        else { return }
        let previousLaunch = DiagnosticLaunchID(string: previous.launch)
        diagnostics.record(.appPreviousExit(exitClass: classification.exitClass, previousLaunch: previousLaunch))
        guard classification.exitClass == .uncleanUnknown else { return }

        try? await Task.sleep(for: .seconds(ExitClassifier.rescanDelay))
        let later = scanner.scan(since: window)
        scanner.store(later, now: now())
        if let upgraded = ExitClassifier.upgrade(classification, previous: previous, reports: later) {
            diagnostics.record(.appPreviousExit(exitClass: upgraded.exitClass, previousLaunch: previousLaunch))
        }
    }

    /// Marks this launch's record clean. Called at quit, after the last
    /// recording is finalised.
    func finish(launch: DiagnosticLaunchID) {
        try? launchRecords.markClean(launch: launch.uuid.uuidString.lowercased())
    }
}
