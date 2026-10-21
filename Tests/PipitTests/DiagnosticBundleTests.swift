import Foundation
import Testing

@testable import PipitCore

/// Assembling a report from the log and the snapshot, and fitting it to the
/// server's limits (`docs/DIAGNOSTICS.md`, Report format).
@Suite("Diagnostic bundle")
struct DiagnosticBundleTests {
    static let created = DiagnosticsFixtures.utc("2026-10-21T03:18:16Z")

    /// The fixture's sections, with `events` and `crashes` for the log.
    static func contents(events: [DiagnosticEvent], crashes: [CrashSummary]? = nil) throws -> DiagnosticBundleContents {
        let fixture = try DiagnosticReport.decode(try Data(contentsOf: DiagnosticsFixtures.report))
        return DiagnosticBundleContents(
            app: fixture.app, system: fixture.system, settings: fixture.summary.settings,
            permissions: fixture.summary.permissions, models: fixture.summary.models,
            browserAddOns: fixture.summary.browserAddOns, storage: fixture.summary.storage,
            recentFailures: fixture.summary.recentFailures, events: events, crashes: crashes ?? fixture.crashes
        )
    }

    static func request(
        _ kind: DiagnosticReport.Kind = .user, note: String? = nil, contact: String? = nil, since: Date? = nil
    ) -> DiagnosticBundleRequest {
        DiagnosticBundleRequest(
            reportID: "5b0c6a3e-8f1d-4c2a-9e7b-1d2f3a4b5c6d", kind: kind, createdAt: created,
            deletionSecretHash: "zJk90jTVjCvAIbe9mWlHJMzML8SbnpzjNUx1hwySPi0", note: note, contact: contact,
            eventsSince: since
        )
    }

    static func events(_ count: Int, from start: Date = created.addingTimeInterval(-86_400)) -> [DiagnosticEvent] {
        (0..<count).map { index in
            DiagnosticEvent(
                time: start.addingTimeInterval(Double(index)), launch: DiagnosticEventTests.launch,
                kind: .processingStageStarted(stage: .transcribing, attempt: index)
            )
        }
    }

    /// Every string in a JSON tree, keys included, but the note and contact.
    static func strings(in value: JSONValue, topLevel: Bool = true) -> [String] {
        switch value {
        case .string(let text): [text]
        case .array(let elements): elements.flatMap { strings(in: $0, topLevel: false) }
        case .object(let members):
            members.flatMap { key, member -> [String] in
                if topLevel, key == "note" || key == "contact" { return [key] }
                return [key] + strings(in: member, topLevel: false)
            }
        case .null, .bool, .integer, .double: []
        }
    }

    // MARK: - compression

    @Test("gzip writes a gzip member that reads back to the same bytes")
    func gzipWritesAGzipMemberThatReadsBackToTheSameBytes() throws {
        for input in [Data(), Data("{}".utf8), Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 * 7) })] {
            let packed = try DiagnosticCompression.gzip(input)
            #expect(Array(packed.prefix(3)) == [0x1F, 0x8B, 0x08])
            #expect(try DiagnosticCompression.gunzip(packed) == input)
            // Deterministic, so a retry can send the body it stored.
            #expect(try DiagnosticCompression.gzip(input) == packed)
        }
        // The trailer is the CRC-32 and the length, little-endian.
        let text = Data("The quick brown fox jumps over the lazy dog".utf8)
        let packed = try DiagnosticCompression.gzip(text)
        #expect(DiagnosticCompression.crc32(text) == 0x414F_A339)
        #expect(Array(packed.suffix(8)) == [0x39, 0xA3, 0x4F, 0x41, 43, 0, 0, 0])
        #expect(throws: DiagnosticCompression.Failure.corrupt) {
            try DiagnosticCompression.gunzip(packed.prefix(packed.count - 4))
        }
        #expect(throws: DiagnosticCompression.Failure.corrupt) { try DiagnosticCompression.gunzip(text) }
    }

    // MARK: - events

    @Test("an event's JSON tree is the line the encoder writes")
    func anEventsJSONTreeIsTheLineTheEncoderWrites() throws {
        let encoder = DiagnosticEventCoding.makeEncoder()
        for (kind, _) in DiagnosticEventTests.samples {
            for event in [
                DiagnosticEvent(time: DiagnosticEventTests.time, launch: DiagnosticEventTests.launch, kind: kind),
                DiagnosticEvent(
                    time: DiagnosticEventTests.time, launch: DiagnosticEventTests.launch,
                    session: DiagnosticEventTests.session, job: DiagnosticEventTests.job, kind: kind, count: 3
                ),
            ] {
                #expect(event.jsonValue == JSONValue.parse(try encoder.encode(event)), "\(kind.name)")
            }
        }
    }

    @Test("the log is read oldest first across files, and a damaged line is skipped")
    func theLogIsReadOldestFirstAcrossFilesAndADamagedLineIsSkipped() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = DiagnosticLayout(root: root)
        try FileManager.default.createDirectory(at: layout.events, withIntermediateDirectories: true)
        let encoder = DiagnosticEventCoding.makeEncoder()
        func lines(_ events: [DiagnosticEvent]) throws -> Data {
            var data = Data()
            for event in events { data.append(try #require(DiagnosticEventCoding.line(event, encoder: encoder))) }
            return data
        }
        let day = Self.created.addingTimeInterval(-3_600)
        let all = Self.events(6, from: day)
        try lines([all[3], all[5]]).write(to: layout.eventsFile(day: DiagnosticLayout.day(of: day), part: 1))
        var first = try lines([all[0], all[2]])
        first.append(Data("{\"v\":1,\"t\":\"not a time\"}\n{\"v\":1,\"kind\":\"sample.unknown\"\n".utf8))
        try first.write(to: layout.eventsFile(day: DiagnosticLayout.day(of: day), part: 0))
        try lines([all[1], all[4]]).write(to: layout.nativeHostFile(day: DiagnosticLayout.day(of: day)))
        try Data("not an event file".utf8).write(to: layout.events.appendingPathComponent("notes.txt"))
        let safari = root.appendingPathComponent("safari-extension.ndjson")
        let late = DiagnosticEvent(
            time: day.addingTimeInterval(100), launch: DiagnosticEventTests.launch,
            kind: .browserAddonDisconnected(browser: .safari, reason: .silence)
        )
        try lines([late]).write(to: safari)

        #expect(layout.storedEvents() == all)
        #expect(layout.storedEvents(additionalFiles: [safari]) == all + [late])
        #expect(DiagnosticLayout(root: root.appendingPathComponent("missing")).storedEvents().isEmpty)
    }

    // MARK: - building

    @Test("a built report passes the token rule everywhere and carries the newest events in order")
    func aBuiltReportPassesTheTokenRuleEverywhereAndCarriesTheNewestEventsInOrder() throws {
        var log = SyntheticDiagnosticLog(seed: 7)
        let events = log.events(days: 2, end: Self.created, meetingsPerDay: 3, chatter: 4)
        let bundle = try DiagnosticBundleBuilder.build(
            try Self.contents(events: events),
            request: Self.request(note: "It stopped after the call / \"quoted\"", contact: "someone@example.com")
        )
        let report = bundle.report
        #expect(DiagnosticReportValidator.violations(in: report).isEmpty)
        let tree = try #require(JSONValue.parse(bundle.json))
        for text in Self.strings(in: tree) {
            #expect(DiagnosticTokenRule.accepts(text), "\(text)")
        }
        #expect(report.events.count == events.count)
        #expect(report.events == events.map(\.jsonValue))
        #expect(report.summary.diagnostics.eventsIncluded == events.count)
        #expect(report.summary.diagnostics.eventsOmitted == 0)
        #expect(report.summary.diagnostics.oldestEvent == events.first?.time)
        let dropped = events.reduce(0) { total, event in
            if case .diagnosticsDropped(let count) = event.kind { return total + count * event.count }
            return total
        }
        #expect(report.summary.diagnostics.eventsDropped == dropped)
        #expect(report.note == "It stopped after the call / \"quoted\"")
        #expect(report.contact == "someone@example.com")
        #expect(try DiagnosticCompression.gunzip(bundle.gzipped) == bundle.json)
        #expect(try report.gzippedJSON() == bundle.gzipped)
        #expect(try report.measuredSize() == bundle.size)
        #expect(try DiagnosticReport.decode(bundle.json) == report)
    }

    @Test("a note and a contact are kept on a user report only, and only when written")
    func aNoteAndAContactAreKeptOnAUserReportOnlyAndOnlyWhenWritten() throws {
        let contents = try Self.contents(events: Self.events(3))
        for kind in [DiagnosticReport.Kind.crash, .automatic] {
            let report = try DiagnosticBundleBuilder.build(
                contents, request: Self.request(kind, note: "Sample note", contact: "someone@example.com")
            ).report
            #expect(report.note == nil)
            #expect(report.contact == nil)
            #expect(report.kind == kind)
        }
        let blank = try DiagnosticBundleBuilder.build(contents, request: Self.request(note: " \n ", contact: "")).report
        #expect(blank.note == nil)
        #expect(blank.contact == nil)
    }

    @Test("events before the request's start are left out without counting as omitted")
    func eventsBeforeTheRequestsStartAreLeftOutWithoutCountingAsOmitted() throws {
        let events = Self.events(10)
        let report = try DiagnosticBundleBuilder.build(
            try Self.contents(events: events), request: Self.request(.automatic, since: events[6].time)
        ).report
        #expect(report.events == events.suffix(4).map(\.jsonValue))
        #expect(report.summary.diagnostics.eventsOmitted == 0)
        #expect(report.summary.diagnostics.oldestEvent == events[0].time)
    }

    @Test("past the event limit the newest are kept and the rest counted")
    func pastTheEventLimitTheNewestAreKeptAndTheRestCounted() throws {
        let events = Self.events(12)
        let budget = DiagnosticBundleBuilder.Budget(compressedBytes: 1 << 20, decompressedBytes: 8 << 20, events: 5)
        let report = try DiagnosticBundleBuilder.build(
            try Self.contents(events: events), request: Self.request(), budget: budget
        ).report
        #expect(report.events == events.suffix(5).map(\.jsonValue))
        #expect(report.summary.diagnostics.eventsIncluded == 5)
        #expect(report.summary.diagnostics.eventsOmitted == 7)
    }

    @Test("past the size limit the oldest go first until the body fits")
    func pastTheSizeLimitTheOldestGoFirstUntilTheBodyFits() throws {
        var log = SyntheticDiagnosticLog(seed: 11)
        let events = log.events(days: 4, end: Self.created, meetingsPerDay: 4, chatter: 30)
        let contents = try Self.contents(events: events)
        let full = try DiagnosticBundleBuilder.build(contents, request: Self.request())
        let budget = DiagnosticBundleBuilder.Budget(
            compressedBytes: full.size.compressed / 3, decompressedBytes: 8 << 20, events: 20_000
        )
        let bundle = try DiagnosticBundleBuilder.build(contents, request: Self.request(), budget: budget)
        let diagnostics = bundle.report.summary.diagnostics
        #expect(bundle.size.compressed <= budget.compressedBytes)
        #expect(diagnostics.eventsOmitted > 0)
        #expect(diagnostics.eventsIncluded + diagnostics.eventsOmitted == events.count)
        #expect(bundle.report.events == events.suffix(diagnostics.eventsIncluded).map(\.jsonValue))
        // Close to the most that fit, not far under it.
        #expect(Double(bundle.size.compressed) > Double(budget.compressedBytes) * 0.85)

        let raw = DiagnosticBundleBuilder.Budget(
            compressedBytes: 1 << 20, decompressedBytes: full.size.raw / 2, events: 20_000
        )
        let halved = try DiagnosticBundleBuilder.build(contents, request: Self.request(), budget: raw)
        #expect(halved.size.raw <= raw.decompressedBytes)
        #expect(halved.report.summary.diagnostics.eventsOmitted > 0)

        let tiny = DiagnosticBundleBuilder.Budget(compressedBytes: 100, decompressedBytes: 8 << 20, events: 20_000)
        #expect(throws: DiagnosticBundleBuilder.Failure.self) {
            try DiagnosticBundleBuilder.build(contents, request: Self.request(), budget: tiny)
        }
    }

    @Test("a report the server would refuse is never produced")
    func aReportTheServerWouldRefuseIsNeverProduced() throws {
        var contents = try Self.contents(events: Self.events(2))
        contents.settings["sample setting"] = .bool(true)
        #expect(throws: DiagnosticBundleBuilder.Failure.invalid([.token(path: "summary.settings.?")])) {
            try DiagnosticBundleBuilder.build(contents, request: Self.request())
        }
        let long = Self.request(note: String(repeating: "a", count: DiagnosticReportLimits.noteLength + 1))
        #expect(throws: DiagnosticBundleBuilder.Failure.invalid([.noteTooLong(4001)])) {
            try DiagnosticBundleBuilder.build(try Self.contents(events: []), request: long)
        }
    }

    @Test("at most ten crashes, newest first as given")
    func atMostTenCrashesNewestFirstAsGiven() throws {
        let fixture = try DiagnosticReport.decode(try Data(contentsOf: DiagnosticsFixtures.report))
        let crashes = (0..<12).map { index -> CrashSummary in
            var crash = fixture.crashes[0]
            crash.incident = "c3d4e5f6-a7b8-4c9d-8e0f-1a2b3c4d5e\(String(format: "%02d", index))"
            return crash
        }
        let report = try DiagnosticBundleBuilder.build(
            try Self.contents(events: [], crashes: crashes), request: Self.request(.crash)
        ).report
        #expect(report.crashes == Array(crashes.prefix(10)))
        #expect(report.summary.diagnostics.oldestEvent == nil)
        #expect(report.summary.diagnostics.eventsIncluded == 0)
    }

    // MARK: - measured

    @Test("fourteen days of use fit the server's limits, with the numbers printed")
    func fourteenDaysOfUseFitTheServersLimitsWithTheNumbersPrinted() throws {
        let cases: [(String, Int, Int)] = [("typical", 4, 3), ("heavy", 8, 300)]
        for (name, meetings, chatter) in cases {
            var log = SyntheticDiagnosticLog(seed: 2026)
            let events = log.events(days: 14, end: Self.created, meetingsPerDay: meetings, chatter: chatter)
            let encoder = DiagnosticEventCoding.makeEncoder()
            let logBytes = try events.reduce(0) { $0 + (try encoder.encode($1).count + 1) }
            let started = Date()
            let bundle = try DiagnosticBundleBuilder.build(try Self.contents(events: events), request: Self.request())
            let elapsed = Date().timeIntervalSince(started)
            let diagnostics = bundle.report.summary.diagnostics
            print(
                "diagnostic bundle \(name): \(events.count) events, \(logBytes) bytes of log; "
                    + "report \(bundle.size.raw) bytes raw, \(bundle.size.compressed) bytes gzip; "
                    + "\(diagnostics.eventsIncluded) included, \(diagnostics.eventsOmitted) omitted; "
                    + String(format: "built in %.2f s", elapsed)
            )
            #expect(bundle.size.compressed <= DiagnosticReportLimits.compressedBytes)
            #expect(bundle.size.raw <= DiagnosticReportLimits.decompressedBytes)
            #expect(diagnostics.eventsIncluded <= DiagnosticReportLimits.events)
            #expect(diagnostics.eventsIncluded + diagnostics.eventsOmitted == events.count)
            if events.count > DiagnosticReportLimits.events {
                #expect(diagnostics.eventsOmitted > 0)
            } else {
                #expect(diagnostics.eventsOmitted == 0)
            }
        }
    }
}
