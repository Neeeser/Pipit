import Foundation

/// How the previous launch ended (`docs/DIAGNOSTICS.md`, Exit classes).
public enum ExitClass: String, Codable, Sendable, CaseIterable {
    case clean
    case crash
    case hang
    case systemRestart = "system_restart"
    case uncleanUnknown = "unclean_unknown"
}

/// An exit class and the crash or hang report that decided it, if one did.
public struct ExitClassification: Codable, Sendable, Equatable {
    public var exitClass: ExitClass
    /// The matching report's incident, for `crash` and `hang`.
    public var incident: String?

    public init(_ exitClass: ExitClass, incident: String? = nil) {
        self.exitClass = exitClass
        self.incident = incident
    }

    private enum CodingKeys: String, CodingKey {
        case exitClass = "class"
        case incident
    }
}

/// Decides how the previous launch ended from its launch record, this boot's
/// session UUID, and the crash reports found since. Pure: the caller reads
/// the record, the boot session, and the reports, and acts on the answer.
public enum ExitClassifier {
    /// ReportCrash can finish its report after Pipit has relaunched, so Pipit
    /// looks again this long after launch.
    public static let rescanDelay: TimeInterval = 120

    /// How far a report's `procLaunch` may sit before the record's start time.
    /// The record takes the kernel's start time when it can, and the time at
    /// launch otherwise, which trails it by however long launching took.
    public static let launchLeadTolerance: TimeInterval = 120
    /// How far it may sit after: the two clocks are read separately and
    /// rounded differently.
    public static let launchLagTolerance: TimeInterval = 2

    /// The previous launch's class, or nil when there is no previous record
    /// to classify.
    ///
    /// A matching crash report decides before `clean` does. A process that
    /// crashed after it wrote `clean`, in a teardown handler, still crashed,
    /// and the report is the stronger evidence.
    public static func classify(
        previous: LaunchRecord?, currentBootSession: String?, reports: [CrashRecord]
    ) -> ExitClassification? {
        guard let previous else { return nil }
        if let report = match(previous, in: reports) {
            return ExitClassification(report.summary.kind == .hang ? .hang : .crash, incident: report.incident)
        }
        if previous.clean { return ExitClassification(.clean) }
        if let before = previous.bootSession, let now = currentBootSession, before != now {
            return ExitClassification(.systemRestart)
        }
        return ExitClassification(.uncleanUnknown)
    }

    /// Whether the delayed rescan is due for a launch that started at
    /// `launchedAt`.
    public static func rescanIsDue(launchedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(launchedAt) >= rescanDelay
    }

    /// The upgraded class when the rescan found the report that was not there
    /// at launch, or nil when nothing changed. Only `unclean_unknown` is
    /// upgraded: a clean exit, a restart, and a match already made stand.
    public static func upgrade(
        _ classification: ExitClassification, previous: LaunchRecord, reports: [CrashRecord]
    ) -> ExitClassification? {
        guard classification.exitClass == .uncleanUnknown, let report = match(previous, in: reports) else {
            return nil
        }
        return ExitClassification(report.summary.kind == .hang ? .hang : .crash, incident: report.incident)
    }

    /// The app's report with the record's pid whose launch time is the
    /// record's. A pid alone repeats across launches and boots, so a report
    /// with no launch time matches only when it was captured after the
    /// launch began. When both name an executable UUID, they must agree.
    static func match(_ record: LaunchRecord, in reports: [CrashRecord]) -> CrashRecord? {
        let matching = reports.filter { report in
            guard report.process == .app, report.pid == record.pid else { return false }
            if let reported = report.binaryUUID, let recorded = record.binaryUUID,
                reported.lowercased() != recorded.lowercased()
            {
                return false
            }
            guard let launchedAt = report.launchedAt else {
                return report.summary.occurredAt >= record.startedAt.addingTimeInterval(-launchLagTolerance)
            }
            let lead = record.startedAt.timeIntervalSince(launchedAt)
            return lead <= launchLeadTolerance && lead >= -launchLagTolerance
        }
        // Two reports for one launch would be a crash while a crash was being
        // reported. The one launched nearest the record's start is that launch's.
        func distance(_ report: CrashRecord) -> TimeInterval {
            abs((report.launchedAt ?? report.summary.occurredAt).timeIntervalSince(record.startedAt))
        }
        return matching.min { distance($0) < distance($1) }
    }
}
