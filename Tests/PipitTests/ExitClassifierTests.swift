import Foundation
import Testing

@testable import PipitCore

/// How the previous launch ended, decided from `state/launch.json`, the boot
/// session, and the crash reports found since (`docs/DIAGNOSTICS.md`, Exit
/// classes).
@Suite("Exit classification")
struct ExitClassifierTests {
    private let bootA = DiagnosticsFixtures.bootA
    private let bootB = DiagnosticsFixtures.bootB

    private func report(_ name: String) throws -> CrashRecord {
        try #require(CrashReportReducer.reduce(try DiagnosticsFixtures.data(name)))
    }

    /// The crash in `pipit-crash.ips`, changed in one respect.
    private func variant(_ change: (inout CrashRecord) -> Void) throws -> CrashRecord {
        var record = try report("pipit-crash")
        change(&record)
        return record
    }

    private func classify(
        _ previous: LaunchRecord?, boot: String? = DiagnosticsFixtures.bootA, reports: [CrashRecord]
    ) -> ExitClassification? {
        ExitClassifier.classify(previous: previous, currentBootSession: boot, reports: reports)
    }

    @Test("each kind of evidence gives its class")
    func eachKindOfEvidenceGivesItsClass() throws {
        let crash = try report("pipit-crash")
        let otherLaunch = try report("pipit-crash-other-pid")
        let incident = crash.incident
        let hang = try variant { $0.summary.kind = .hang }
        let launch = DiagnosticsFixtures.crashedLaunch()
        let cleanLaunch = DiagnosticsFixtures.crashedLaunch(clean: true)

        struct Case {
            let name: String
            let previous: LaunchRecord
            let boot: String?
            let reports: [CrashRecord]
            let expected: ExitClassification
        }
        let unknownBoot = DiagnosticsFixtures.crashedLaunch(bootSession: nil)
        let table = [
            Case(name: "clean, no report", previous: cleanLaunch, boot: bootA, reports: [], expected: .init(.clean)),
            Case(
                name: "clean, after a restart", previous: cleanLaunch, boot: bootB, reports: [], expected: .init(.clean)
            ),
            Case(
                name: "a matching crash report", previous: launch, boot: bootA, reports: [otherLaunch, crash],
                expected: .init(.crash, incident: incident)),
            Case(
                name: "a matching report after a restart", previous: launch, boot: bootB, reports: [crash],
                expected: .init(.crash, incident: incident)),
            // A crash in a teardown handler, after `clean` was written.
            Case(
                name: "clean, and a matching report", previous: cleanLaunch, boot: bootA, reports: [crash],
                expected: .init(.crash, incident: incident)),
            Case(
                name: "a matching hang report", previous: launch, boot: bootA, reports: [hang],
                expected: .init(.hang, incident: incident)),
            Case(
                name: "a restart, no report", previous: launch, boot: bootB, reports: [otherLaunch],
                expected: .init(.systemRestart)),
            Case(
                name: "same boot, no report", previous: launch, boot: bootA, reports: [otherLaunch],
                expected: .init(.uncleanUnknown)),
            Case(name: "this boot unknown", previous: launch, boot: nil, reports: [], expected: .init(.uncleanUnknown)),
            Case(
                name: "the record's boot unknown", previous: unknownBoot, boot: bootB, reports: [],
                expected: .init(.uncleanUnknown)),
        ]
        for row in table {
            #expect(classify(row.previous, boot: row.boot, reports: row.reports) == row.expected, "\(row.name)")
        }
        #expect(classify(nil, reports: [crash]) == nil)
    }

    @Test("a report matches only the app's own launch: same pid, launch time and executable")
    func aReportMatchesOnlyTheAppsOwnLaunchSamePidLaunchTimeAndExecutable() throws {
        let launch = DiagnosticsFixtures.crashedLaunch()
        let mismatches = [
            try variant { $0.pid = 4243 },
            try variant { $0.process = .nativeHost },
            // The same pid from a launch two hours earlier.
            try variant { $0.launchedAt = launch.startedAt.addingTimeInterval(-7200) },
            // A process that started after the record did is not that launch.
            try variant { $0.launchedAt = launch.startedAt.addingTimeInterval(30) },
            try variant { $0.binaryUUID = "ffffffff-5e6f-4a7b-8c9d-0e1f2a3b4c5d" },
            // No launch time, and captured before the launch began.
            try variant {
                $0.launchedAt = nil
                $0.summary.occurredAt = launch.startedAt.addingTimeInterval(-60)
            },
        ]
        for report in mismatches {
            #expect(classify(launch, reports: [report]) == .init(.uncleanUnknown))
        }

        let matches = [
            // The record was written a minute into launching.
            try variant { $0.launchedAt = launch.startedAt.addingTimeInterval(-60) },
            try variant { $0.binaryUUID = nil },
            try variant { $0.binaryUUID = $0.binaryUUID?.uppercased() },
            try variant { $0.launchedAt = nil },
        ]
        for report in matches {
            #expect(classify(launch, reports: [report])?.exitClass == .crash)
        }
    }

    @Test("of two reports for one launch, the one launched nearest the record wins")
    func ofTwoReportsForOneLaunchTheOneLaunchedNearestTheRecordWins() throws {
        let launch = DiagnosticsFixtures.crashedLaunch()
        let near = try report("pipit-crash")
        let far = try variant {
            $0.summary.incident = "00000000-0000-4000-8000-000000000001"
            $0.launchedAt = launch.startedAt.addingTimeInterval(-100)
        }
        #expect(classify(launch, reports: [far, near]) == .init(.crash, incident: near.incident))
    }

    @Test("the rescan upgrades only unclean_unknown, and only when a matching report appeared")
    func theRescanUpgradesOnlyUncleanUnknownAndOnlyWhenAMatchingReportAppeared() throws {
        let launch = DiagnosticsFixtures.crashedLaunch()
        let crash = try report("pipit-crash")
        let unknown = try #require(classify(launch, reports: []))
        #expect(unknown == .init(.uncleanUnknown))

        #expect(ExitClassifier.upgrade(unknown, previous: launch, reports: []) == nil)
        #expect(
            ExitClassifier.upgrade(unknown, previous: launch, reports: [try report("pipit-crash-other-pid")]) == nil
        )
        #expect(
            ExitClassifier.upgrade(unknown, previous: launch, reports: [crash])
                == .init(.crash, incident: crash.incident)
        )
        for settled in [ExitClassification(.clean), .init(.systemRestart), .init(.crash, incident: crash.incident)] {
            #expect(ExitClassifier.upgrade(settled, previous: launch, reports: [crash]) == nil)
        }

        let start = launch.startedAt
        #expect(!ExitClassifier.rescanIsDue(launchedAt: start, now: start.addingTimeInterval(119)))
        #expect(ExitClassifier.rescanIsDue(launchedAt: start, now: start.addingTimeInterval(120)))
    }

    @Test("the classification encodes as the event payload names it")
    func theClassificationEncodesAsTheEventPayloadNamesIt() throws {
        let encoded = try DiagnosticCoding.makeReportEncoder().encode(ExitClassification(.uncleanUnknown))
        #expect(String(data: encoded, encoding: .utf8) == #"{"class":"unclean_unknown"}"#)
        #expect(ExitClass.allCases.map(\.rawValue) == ["clean", "crash", "hang", "system_restart", "unclean_unknown"])
    }

    // MARK: launch record

    @Test("a launch record survives a round trip, fractions of a second included")
    func aLaunchRecordSurvivesARoundTripFractionsOfASecondIncluded() throws {
        let directory = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LaunchRecordStore(directory: directory.appendingPathComponent("state", isDirectory: true))
        #expect(store.load() == nil)

        let first = DiagnosticsFixtures.crashedLaunch()
        #expect(try store.begin(first) == nil)
        #expect(store.load() == first)

        let data = try Data(contentsOf: store.file)
        let tree = try #require(JSONValue.parse(data)?.objectValue)
        #expect(Set(tree.keys) == ["launch", "pid", "startedAt", "bootSession", "binaryUUID", "version", "clean"])
        #expect(tree["startedAt"] == .string("2026-10-21T10:10:00.500Z"))
        for value in tree.values {
            if case .string(let text) = value { #expect(DiagnosticTokenRule.accepts(text)) }
        }

        var second = first
        second.launch = "1a7f3b2c-4d5e-4f60-8172-93a4b5c6d7e8"
        second.pid = 5150
        #expect(try store.begin(second) == first)
        #expect(store.load() == second)
    }

    @Test("only the launch that wrote the record can mark it clean")
    func onlyTheLaunchThatWroteTheRecordCanMarkItClean() throws {
        let directory = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LaunchRecordStore(directory: directory)
        let launch = DiagnosticsFixtures.crashedLaunch()
        try store.save(launch)

        try store.markClean(launch: "7d3c2b1a-0f9e-4d8c-b7a6-5f4e3d2c1b0a")
        #expect(store.load()?.clean == false)
        try store.markClean(launch: launch.launch)
        #expect(store.load()?.clean == true)
    }

    @Test("a damaged launch record reads as none")
    func aDamagedLaunchRecordReadsAsNone() throws {
        let directory = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LaunchRecordStore(directory: directory)
        try Data(#"{"launch":"x","pid":"#.utf8).write(to: store.file)
        #expect(store.load() == nil)
        // Clearing diagnostics while Pipit runs must not stop a clean exit.
        try FileManager.default.removeItem(at: store.file)
        try store.markClean(launch: "x")
        #expect(store.load() == nil)
    }
}
