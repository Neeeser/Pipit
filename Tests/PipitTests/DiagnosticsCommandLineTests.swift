import Foundation
import PipitCore
import Testing

@testable import PipitCLIKit

/// `pipit diagnostics crashes`, run against a scratch home directory holding
/// synthetic crash reports and a launch record.
@Suite("Diagnostics command line")
struct DiagnosticsCommandLineTests {
    /// A scratch home with the Logs folders the app and ReportCrash write.
    private struct Machine {
        let home: URL
        let bootSession: String?

        init(bootSession: String? = DiagnosticsFixtures.bootA) throws {
            home = try TestPaths.makeTemporaryDirectory()
            self.bootSession = bootSession
        }

        func cleanUp() { try? FileManager.default.removeItem(at: home) }

        var reports: URL { home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true) }
        var logs: URL { home.appendingPathComponent("Library/Logs/Pipit", isDirectory: true) }

        func run(_ arguments: String...) -> CommandResult {
            PipitCommandLine.run(
                arguments,
                environment: CLIEnvironment(
                    home: home, supportDirectory: home.appendingPathComponent("Support"),
                    executable: home.appendingPathComponent("Pipit.app/Contents/MacOS/pipit-cli"),
                    pathVariable: "/usr/bin", bootSession: bootSession
                )
            )
        }

        func place(_ fixture: String, as name: String) throws {
            try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            try DiagnosticsFixtures.data(fixture).write(to: reports.appendingPathComponent(name))
        }

        func record(_ record: LaunchRecord) throws {
            try LaunchRecordStore(directory: LaunchRecordStore.defaultDirectory(home: home)).save(record)
        }

        /// Everything under the scratch home, to show the command wrote nothing.
        func tree() -> [String] {
            let enumerator = FileManager.default.enumerator(atPath: home.path)
            return (enumerator?.allObjects as? [String] ?? []).sorted()
        }
    }

    private func listing(_ result: CommandResult) throws -> CrashListing {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CrashListing.self, from: Data(result.standardOutput.utf8))
    }

    /// A pid no process has: above the highest pid macOS and Linux hand out.
    private let deadPid: Int32 = 2_000_000_000

    @Test("crashes lists Pipit's reports and says the last launch crashed")
    func crashesListsPipitsReportsAndSaysTheLastLaunchCrashed() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        try machine.place("pipit-crash", as: "Pipit-2026-10-21-031816.ips")
        try machine.place("pipit-crash-other-pid", as: "Pipit-2026-10-21-050000.ips")
        try machine.place("other-app-crash", as: "SampleEditor-2026-10-21-031816.ips")
        try machine.place("truncated", as: "Pipit-2026-10-21-060000.ips")
        try machine.record(DiagnosticsFixtures.crashedLaunch())
        let before = machine.tree()

        let result = machine.run("diagnostics", "crashes", "--json")
        #expect(result.exitCode == 0)
        let listing = try listing(result)
        #expect(listing.schemaVersion == 1)
        #expect(listing.reportsDirectory == machine.reports.path)
        #expect(listing.crashes.map(\.pid) == [5151, 4242])
        let crashed = try #require(listing.crashes.last)
        let launch = try #require(listing.lastLaunch)
        #expect(launch.pid == crashed.pid)
        #expect(launch.binaryUUID == crashed.binaryUUID)
        #expect(launch.running == false)
        #expect(launch.exit == .crash)
        #expect(launch.incident == crashed.incident)
        #expect(!result.standardOutput.contains("CANARY"))
        // Read-only: no summary stored, no record rewritten.
        #expect(machine.tree() == before)

        let text = machine.run("diagnostics", "crashes").standardOutput
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("last launch: ") == true)
        #expect(lines.first?.hasSuffix("crash  c3d4e5f6-a7b8-4c9d-8e0f-1a2b3c4d5e6f") == true)
        #expect(lines.count == 3)
        #expect(lines.last?.split(separator: "\t").first == "c3d4e5f6-a7b8-4c9d-8e0f-1a2b3c4d5e6f")
        #expect(lines.last?.hasSuffix("\tapp\t4242\tEXC_BAD_ACCESS\tSIGSEGV\tSIGNAL.11") == true)
    }

    @Test("a summary the app already kept is listed after ReportCrash retired the report")
    func aSummaryTheAppAlreadyKeptIsListedAfterReportCrashRetiredTheReport() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        try machine.place("pipit-crash", as: "Pipit-2026-10-21-031816.ips")
        let scanner = CrashReportScanner(home: machine.home)
        let now = DiagnosticsFixtures.utc("2026-10-22T00:00:00Z")
        #expect(scanner.scanAndStore(now: now).count == 1)
        try FileManager.default.removeItem(at: machine.reports)

        let listing = try listing(machine.run("diagnostics", "crashes", "--json"))
        #expect(listing.crashes.map(\.incident) == ["c3d4e5f6-a7b8-4c9d-8e0f-1a2b3c4d5e6f"])
        #expect(listing.lastLaunch == nil)
    }

    @Test("a launch killed without a report is unclean_unknown, and one after a restart is system_restart")
    func aLaunchKilledWithoutAReportIsUncleanUnknownAndOneAfterARestartIsSystemRestart() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        try machine.place("pipit-crash", as: "Pipit-2026-10-21-031816.ips")
        var killed = DiagnosticsFixtures.crashedLaunch()
        killed.pid = deadPid
        try machine.record(killed)

        let launch = try #require(try listing(machine.run("diagnostics", "crashes", "--json")).lastLaunch)
        #expect(launch.running == false)
        #expect(launch.exit == .uncleanUnknown)
        #expect(launch.incident == nil)
        #expect(machine.run("diagnostics", "crashes").standardOutput.hasPrefix("last launch: "))
        #expect(
            machine.run("diagnostics", "crashes").standardOutput.split(separator: "\n").first?
                .hasSuffix("unclean_unknown") == true
        )

        let restarted = try Machine(bootSession: DiagnosticsFixtures.bootB)
        defer { restarted.cleanUp() }
        try restarted.record(killed)
        #expect(try listing(restarted.run("diagnostics", "crashes", "--json")).lastLaunch?.exit == .systemRestart)
    }

    @Test("a launch that is still running is reported as running, and a clean one as clean")
    func aLaunchThatIsStillRunningIsReportedAsRunningAndACleanOneAsClean() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        var running = DiagnosticsFixtures.crashedLaunch()
        running.pid = ProcessInfo.processInfo.processIdentifier
        try machine.record(running)

        let launch = try #require(try listing(machine.run("diagnostics", "crashes", "--json")).lastLaunch)
        #expect(launch.running == true)
        #expect(launch.exit == nil)
        #expect(machine.run("diagnostics", "crashes").standardOutput.hasSuffix("running\n"))

        running.clean = true
        try machine.record(running)
        let clean = try #require(try listing(machine.run("diagnostics", "crashes", "--json")).lastLaunch)
        #expect(clean.running == false)
        #expect(clean.exit == .clean)
    }

    @Test("with nothing recorded the command says so and succeeds")
    func withNothingRecordedTheCommandSaysSoAndSucceeds() throws {
        let machine = try Machine(bootSession: nil)
        defer { machine.cleanUp() }
        let result = machine.run("diagnostics", "crashes")
        #expect(result.exitCode == 0)
        #expect(result.standardOutput == "last launch: none recorded\n")
        let listing = try listing(machine.run("diagnostics", "crashes", "--json"))
        #expect(listing.lastLaunch == nil)
        #expect(listing.crashes.isEmpty)
    }

    @Test("crashes takes --json and nothing else")
    func crashesTakesJSONAndNothingElse() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        for arguments in [
            ["diagnostics", "crashes", "--root", "/tmp"], ["diagnostics", "crashes", "--limit", "3"],
            ["diagnostics"], ["diagnostics", "crashes", "extra"],
        ] {
            let result = PipitCommandLine.run(
                arguments,
                environment: CLIEnvironment(
                    home: machine.home, supportDirectory: machine.home, executable: machine.home,
                    pathVariable: ""
                )
            )
            #expect(result.exitCode == 2, "\(arguments)")
            #expect(result.standardOutput.isEmpty)
        }
        #expect(try Invocation.parse(["diagnostics", "crashes", "--json"]).command == .crashes)
        #expect(machine.run("--help").standardOutput.contains("pipit diagnostics crashes"))
    }
}
