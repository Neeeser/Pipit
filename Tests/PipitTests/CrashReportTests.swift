import Foundation
import Testing

@testable import PipitCore

/// Reducing Apple's `.ips` crash reports to the summary a diagnostic report
/// may carry, and keeping those summaries in `crashes/`. Every report here is
/// synthetic, written to look like what ReportCrash writes.
@Suite("Crash reports")
struct CrashReportTests {
    private func reduced(_ name: String) throws -> CrashRecord {
        try #require(CrashReportReducer.reduce(try DiagnosticsFixtures.data(name)))
    }

    /// Every string in `value`'s JSON, keys included.
    private func strings(in value: JSONValue) -> [String] {
        switch value {
        case .string(let text): [text]
        case .array(let elements): elements.flatMap(strings(in:))
        case .object(let members): members.flatMap { [$0.key] + strings(in: $0.value) }
        case .null, .bool, .integer, .double: []
        }
    }

    // MARK: reduction

    @Test("a crash keeps the faulting thread's frames and only the images they name")
    func aCrashKeepsTheFaultingThreadsFramesAndOnlyTheImagesTheyName() throws {
        let record = try reduced("pipit-crash")
        #expect(record.process == .app)
        #expect(record.pid == 4242)
        #expect(record.binaryUUID == "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d")
        let launchedAt = try #require(record.launchedAt)
        #expect(abs(launchedAt.timeIntervalSince(DiagnosticsFixtures.utc("2026-10-21T10:10:00Z")) - 0.1234) < 0.001)

        let summary = record.summary
        #expect(summary.incident == "c3d4e5f6-a7b8-4c9d-8e0f-1a2b3c4d5e6f")
        #expect(summary.kind == .crash)
        #expect(DiagnosticCoding.string(from: summary.occurredAt) == "2026-10-21T10:18:16Z")
        #expect(summary.app == CrashSummary.App(version: "0.1.8", build: 812))
        #expect(summary.os == "15.6.1")
        #expect(summary.osBuild == "24G90")
        #expect(summary.exceptionType == "EXC_BAD_ACCESS")
        #expect(summary.signal == "SIGSEGV")
        #expect(summary.termination == "SIGNAL.11")
        #expect(summary.faultingThread == 1)

        // Thread 0's image and the last exception's image are not named by a
        // faulting frame, so they are not listed. The frame whose image index
        // is out of range is dropped. The rest index the reduced list.
        #expect(
            summary.frames == [
                .init(image: 2, offset: 1000), .init(image: 0, offset: 123_456), .init(image: 5, offset: 5000),
                .init(image: 4, offset: 42), .init(image: 3, offset: 77), .init(image: 1, offset: 7890),
                .init(image: 0, offset: 200),
            ]
        )
        #expect(
            summary.images == [
                .init(name: "Pipit", uuid: "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", arch: "arm64", base: 4_295_000_064),
                .init(
                    name: "libswiftCore.dylib", uuid: "2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e", arch: "arm64",
                    base: 6_442_450_944),
                // A plug-in in the person's home folder: neither its name nor
                // its UUID is kept.
                .init(name: "other", uuid: nil, arch: "arm64", base: 7_000_000_000),
                // Inside the bundle, so named.
                .init(
                    name: "Sparkle", uuid: "5e6f7a8b-9cad-4ebf-9021-4c5d6e7f8091", arch: "arm64",
                    base: 4_296_000_000),
                // A system image whose name breaks the token rule.
                .init(
                    name: "invalid", uuid: "7a8b9cad-becf-40d1-b243-6e7f8091a2b3", arch: "arm64e",
                    base: 7_300_000_000),
                .init(
                    name: "AppKit", uuid: "8b9cadbe-cfd0-41e2-8354-7f8091a2b3c4", arch: "arm64e",
                    base: 7_400_000_000),
            ]
        )
    }

    @Test("nothing the contract drops survives the reduction, and every string passes the token rule")
    func nothingTheContractDropsSurvivesTheReductionAndEveryStringPassesTheTokenRule() throws {
        for name in ["pipit-crash", "pipit-crash-other-pid", "older-layout"] {
            let record = try reduced(name)
            // Compact, as a report is sent, so a space can only come from a value.
            let encoded = try DiagnosticCoding.makeReportEncoder().encode(record)
            let text = try #require(String(data: encoded, encoding: .utf8))
            for canary in ["CANARY", "samplename", "Sample", "USER", "/", "@", " "] {
                #expect(!text.contains(canary), "\(name) kept \(canary)")
            }
            let tree = try #require(JSONValue.parse(encoded))
            for string in strings(in: tree) {
                #expect(DiagnosticTokenRule.accepts(string), "\(name): a string breaks the token rule")
            }
        }
    }

    @Test("another application's report is not read, even one called Pipit")
    func anotherApplicationsReportIsNotReadEvenOneCalledPipit() throws {
        #expect(CrashReportReducer.reduce(try DiagnosticsFixtures.data("other-app-crash")) == nil)
        #expect(CrashReportReducer.reduce(try DiagnosticsFixtures.data("same-name-other-app")) == nil)
    }

    @Test("a cut-off report, a stackshot and bytes that are not a report reduce to nothing")
    func aCutOffReportAStackshotAndBytesThatAreNotAReportReduceToNothing() throws {
        #expect(CrashReportReducer.reduce(try DiagnosticsFixtures.data("truncated")) == nil)
        #expect(CrashReportReducer.reduce(try DiagnosticsFixtures.data("stackshot")) == nil)
        let crash = try DiagnosticsFixtures.data("pipit-crash")
        let headerOnly = crash.prefix(through: try #require(crash.firstIndex(of: UInt8(ascii: "\n"))))
        for data in [Data(), Data("not json\n{}".utf8), Data("{\"bug_type\":\"309\"}".utf8), headerOnly] {
            #expect(CrashReportReducer.reduce(data) == nil)
        }
        #expect(CrashReportReducer.reduce(contentsOf: DiagnosticsFixtures.ips("missing")) == nil)
    }

    @Test("a report without a pid, an incident or a time reduces to nothing")
    func aReportWithoutAPidAnIncidentOrATimeReducesToNothing() throws {
        let (header, body) = try DiagnosticsFixtures.parts("pipit-crash")
        var noPid = body
        noPid["pid"] = nil
        var badIncident = (header, body)
        badIncident.0["incident_id"] = "CANARY not a uuid"
        badIncident.1["incident"] = nil
        var noTime = (header, body)
        noTime.0["timestamp"] = nil
        noTime.1["captureTime"] = "yesterday"
        for (header, body) in [(header, noPid), badIncident, noTime] {
            #expect(CrashReportReducer.reduce(try DiagnosticsFixtures.ipsData(header: header, body: body)) == nil)
        }
    }

    @Test("a report the process survived is not a crash")
    func aReportTheProcessSurvivedIsNotACrash() throws {
        let (header, body) = try DiagnosticsFixtures.parts("pipit-crash")
        for (key, value) in [("isNonFatal", true as Any), ("isNonFatal", "true"), ("isSimulated", true)] {
            var flagged = body
            flagged[key] = value
            #expect(CrashReportReducer.reduce(try DiagnosticsFixtures.ipsData(header: header, body: flagged)) == nil)
        }
        var corpse = body
        corpse["isCorpse"] = true
        #expect(CrashReportReducer.reduce(try DiagnosticsFixtures.ipsData(header: header, body: corpse)) != nil)
    }

    @Test("an older layout falls back to the header and to the triggered thread")
    func anOlderLayoutFallsBackToTheHeaderAndToTheTriggeredThread() throws {
        let record = try reduced("older-layout")
        #expect(record.process == .nativeHost)
        #expect(record.pid == 777)
        #expect(record.launchedAt == nil)
        #expect(record.binaryUUID == "0b1c2d3e-4f50-4172-8394-a5b6c7d8e9f0")
        let summary = record.summary
        #expect(summary.incident == "0a1b2c3d-4e5f-4061-8728-394a5b6c7d8e")
        #expect(summary.occurredAt == DiagnosticsFixtures.utc("2026-10-20T07:00:00Z"))
        #expect(summary.app == CrashSummary.App(version: "unknown", build: 0))
        #expect(summary.os == "14.7")
        #expect(summary.osBuild == "23H124")
        #expect(summary.exceptionType == "EXC_CRASH")
        #expect(summary.signal == nil)
        #expect(summary.termination == nil)
        #expect(summary.faultingThread == 1)
        // The frame without an offset cannot be symbolicated and is dropped.
        #expect(summary.frames == [.init(image: 0, offset: 300), .init(image: 1, offset: 500)])
        #expect(
            summary.images == [
                .init(
                    name: "pipit-nativehost", uuid: "0b1c2d3e-4f50-4172-8394-a5b6c7d8e9f0", arch: "x86_64",
                    base: 4_294_967_296),
                // Named from its path; its UUID was not one.
                .init(name: "libsystem_kernel.dylib", uuid: nil, arch: "x86_64", base: 140_703_128_616_960),
            ]
        )
    }

    @Test("the faulting thread keeps at most 128 frames, counted from the top")
    func theFaultingThreadKeepsAtMost128FramesCountedFromTheTop() throws {
        var (header, body) = try DiagnosticsFixtures.parts("pipit-crash")
        let frames = (0..<300).map { ["imageIndex": 0, "imageOffset": $0, "symbol": "CANARY-\($0)"] as [String: Any] }
        body["threads"] = [["triggered": true, "frames": frames]]
        body["faultingThread"] = 0
        header["incident_id"] = "2C3D4E5F-6071-4283-94A5-B6C7D8E9F0A1"
        let summary = try #require(
            CrashReportReducer.reduce(try DiagnosticsFixtures.ipsData(header: header, body: body))
        ).summary
        #expect(summary.frames.count == CrashSummary.maximumFrames)
        #expect(summary.frames.first == .init(image: 0, offset: 0))
        #expect(summary.frames.last == .init(image: 0, offset: 127))
        #expect(summary.images.map(\.name) == ["Pipit"])
    }

    @Test("each of Pipit's executables is known by its identifier, or by its name when there is none")
    func eachOfPipitsExecutablesIsKnownByItsIdentifierOrByItsNameWhenThereIsNone() {
        for process in PipitProcess.allCases {
            #expect(PipitProcess.matching(name: "anything", identifier: process.identifier) == process)
            #expect(PipitProcess.matching(name: process.executableName, identifier: nil) == process)
            #expect(PipitProcess.matching(name: process.executableName, identifier: "") == process)
            #expect(PipitProcess.matching(name: process.executableName, identifier: "com.example.other") == nil)
        }
        #expect(PipitProcess.matching(name: "pipit", identifier: nil) == nil)
        #expect(PipitProcess.matching(name: nil, identifier: nil) == nil)
    }

    @Test("ReportCrash's local times are read with their offset and any number of fractional digits")
    func reportCrashsLocalTimesAreReadWithTheirOffsetAndAnyNumberOfFractionalDigits() {
        let utc = DiagnosticsFixtures.utc
        #expect(CrashReportReducer.reportTime("2026-10-21 03:18:16 -0700") == utc("2026-10-21T10:18:16Z"))
        #expect(CrashReportReducer.reportTime("2026-10-21 03:18:16.50 +0530") == utc("2026-10-20T21:48:16.500Z"))
        #expect(CrashReportReducer.reportTime("2026-01-01 00:00:00.0000 +0000") == utc("2026-01-01T00:00:00Z"))
        for text in [
            "", "2026-10-21T03:18:16Z", "2026-10-21 03:18 -0700", "2026-13-01 00:00:00 +0000",
            "2026-10-21 03:18:16.x -0700", "2026-10-21 03:18:16 0700", "2026-10-21 03:18:16 -07:00",
        ] {
            #expect(CrashReportReducer.reportTime(text) == nil, "\(text)")
        }
    }

    // MARK: scanning

    /// A scratch Logs folder: ReportCrash's folder and Pipit's `crashes/`.
    private struct Logs {
        let root: URL
        let scanner: CrashReportScanner

        init() throws {
            root = try TestPaths.makeTemporaryDirectory()
            scanner = CrashReportScanner(home: root)
            try FileManager.default.createDirectory(at: scanner.reportsDirectory, withIntermediateDirectories: true)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func place(_ fixture: String, as name: String, modified: Date? = nil) throws -> URL {
            let url = scanner.reportsDirectory.appendingPathComponent(name)
            try DiagnosticsFixtures.data(fixture).write(to: url)
            if let modified {
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            }
            return url
        }

        var storedFiles: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: scanner.crashesDirectory.path)) ?? []).sorted()
        }
    }

    /// A reduced crash with an invented incident, `daysAgo` days before `now`.
    private func crash(_ number: Int, daysAgo: Double, now: Date) -> CrashRecord {
        let incident = String(format: "00000000-0000-4000-8000-%012d", number)
        return CrashRecord(
            process: .app, pid: Int32(1000 + number), launchedAt: nil, binaryUUID: nil,
            summary: CrashSummary(
                incident: incident, kind: .crash, occurredAt: now.addingTimeInterval(-daysAgo * 86_400),
                app: .init(version: "0.1.8", build: 812), os: "15.6.1", osBuild: "24G90",
                exceptionType: "EXC_CRASH", signal: "SIGABRT", termination: "SIGNAL.6", faultingThread: 0,
                frames: [], images: []
            )
        )
    }

    @Test("a scan reads only Pipit's reports, once per incident, newest first")
    func aScanReadsOnlyPipitsReportsOncePerIncidentNewestFirst() throws {
        let logs = try Logs()
        defer { logs.cleanUp() }
        try logs.place("pipit-crash", as: "Pipit-2026-10-21-031816.ips")
        try logs.place("pipit-crash", as: "Pipit-2026-10-21-031816-1.ips")
        try logs.place("pipit-crash-other-pid", as: "Pipit-2026-10-21-050000.ips")
        try logs.place("older-layout", as: "pipit-nativehost-2026-10-20-090000.ips")
        try logs.place("truncated", as: "Pipit-2026-10-21-060000.ips")
        try logs.place("stackshot", as: "Pipit-2026-10-21-033000.ips")
        try logs.place("same-name-other-app", as: "Pipit-2026-10-21-070000.ips")
        try logs.place("other-app-crash", as: "SampleEditor-2026-10-21-031816.ips")
        // Not named like one of Pipit's reports, so not even opened.
        try logs.place("pipit-crash", as: "Pipit.ips.txt")

        let found = logs.scanner.scan()
        #expect(found.map(\.pid) == [5151, 4242, 777])
        #expect(logs.storedFiles.isEmpty)
    }

    @Test("a scan since a date passes over reports written before it")
    func aScanSinceADatePassesOverReportsWrittenBeforeIt() throws {
        let logs = try Logs()
        defer { logs.cleanUp() }
        let now = DiagnosticsFixtures.utc("2026-10-21T12:00:00Z")
        try logs.place("pipit-crash", as: "Pipit-a.ips", modified: now.addingTimeInterval(-3600))
        try logs.place("pipit-crash-other-pid", as: "Pipit-b.ips", modified: now.addingTimeInterval(-60))
        #expect(logs.scanner.scan(since: now.addingTimeInterval(-600)).map(\.pid) == [5151])
    }

    @Test("a folder that is missing or unreadable gives nothing and throws nothing")
    func aFolderThatIsMissingOrUnreadableGivesNothingAndThrowsNothing() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanner = CrashReportScanner(home: root.appendingPathComponent("absent"))
        #expect(scanner.scan().isEmpty)
        #expect(scanner.stored().isEmpty)
        #expect(scanner.scanAndStore(now: Date()).isEmpty)
    }

    @Test("crashes keeps each incident once, the ten newest, and nothing older than 90 days")
    func crashesKeepsEachIncidentOnceTheTenNewestAndNothingOlderThan90Days() throws {
        let logs = try Logs()
        defer { logs.cleanUp() }
        let now = DiagnosticsFixtures.utc("2026-10-21T12:00:00Z")
        let records = (1...12).map { crash($0, daysAgo: Double($0), now: now) } + [crash(13, daysAgo: 91, now: now)]

        let written = logs.scanner.store(records, now: now)
        #expect(written.map(\.pid) == (1...10).map { Int32(1000 + $0) })
        #expect(logs.storedFiles.count == 10)
        #expect(logs.scanner.stored().map(\.summary.incident) == records.prefix(10).map(\.summary.incident))

        // The same records again: nothing new, nothing written.
        #expect(logs.scanner.store(records, now: now).isEmpty)
        // A newer crash pushes the oldest kept one out.
        let newest = crash(14, daysAgo: 0.5, now: now)
        #expect(logs.scanner.store([newest], now: now) == [newest])
        #expect(logs.scanner.stored().first == newest)
        #expect(!logs.storedFiles.contains(CrashReportScanner.fileName(for: records[9].incident)))

        // Time passes: summaries past 90 days go.
        let later = now.addingTimeInterval(85 * 86_400)
        #expect(logs.scanner.trim(now: later).map(\.pid) == [1014, 1001, 1002, 1003, 1004, 1005])
    }

    @Test("a damaged file in crashes is removed and the scan stores what it finds")
    func aDamagedFileInCrashesIsRemovedAndTheScanStoresWhatItFinds() throws {
        let logs = try Logs()
        defer { logs.cleanUp() }
        let now = DiagnosticsFixtures.utc("2026-10-22T12:00:00Z")
        try FileManager.default.createDirectory(at: logs.scanner.crashesDirectory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: logs.scanner.crashesDirectory.appendingPathComponent("damaged.json"))
        try logs.place("pipit-crash", as: "Pipit-2026-10-21-031816.ips")

        let stored = logs.scanner.scanAndStore(now: now)
        #expect(stored.map(\.pid) == [4242])
        #expect(logs.storedFiles == ["c3d4e5f6-a7b8-4c9d-8e0f-1a2b3c4d5e6f.json"])
        #expect(logs.scanner.stored().map(\.incident) == stored.map(\.incident))
        #expect(logs.scanner.scanAndStore(now: now).isEmpty)
    }
}
