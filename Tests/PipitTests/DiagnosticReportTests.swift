import Foundation
import Testing

@testable import PipitCore

/// The schema 1 report and the checks the app runs before export or send,
/// which mirror the report service's (`docs/DIAGNOSTICS.md`, Report format).
@Suite("Diagnostic report")
struct DiagnosticReportTests {
    private func fixture() throws -> DiagnosticReport {
        try DiagnosticReport.decode(try Data(contentsOf: DiagnosticsFixtures.report))
    }

    @Test("the shared fixture decodes, passes the checks, and encodes back to the same JSON")
    func theSharedFixtureDecodesPassesTheChecksAndEncodesBackToTheSameJSON() throws {
        let original = try Data(contentsOf: DiagnosticsFixtures.report)
        let report = try DiagnosticReport.decode(original)
        #expect(report.schemaVersion == 1)
        #expect(report.kind == .user)
        #expect(report.crashes.first?.kind == .crash)
        #expect(report.crashes.first?.process == .app)
        #expect(report.crashes.first?.frames.count == 2)
        #expect(report.events.count == report.summary.diagnostics.eventsIncluded)
        #expect(DiagnosticReportValidator.violations(in: report).isEmpty)
        try DiagnosticReportValidator.validate(report)

        // Nothing is lost or renamed: the types match the contract.
        #expect(JSONValue.parse(try report.encoded()) == JSONValue.parse(original))
    }

    @Test("a space, a slash, an at sign or a quote in any string but the note and contact is refused")
    func aSpaceASlashAnAtSignOrAQuoteInAnyStringButTheNoteAndContactIsRefused() throws {
        let cases: [(String, (inout DiagnosticReport) -> Void)] = [
            ("app.channel", { $0.app.channel = "beta channel" }),
            ("system.hardware", { $0.system.hardware = "Mac15,3/sample" }),
            ("reportID", { $0.reportID = "someone@example.com" }),
            ("summary.settings.metadataModel", { $0.summary.settings["metadataModel"] = .string("\"quoted\"") }),
            ("summary.permissions.calendar", { $0.summary.permissions["calendar"] = "not determined" }),
            ("summary.models[0].revision", { $0.summary.models[0].revision = "/Users/samplename/model" }),
            ("crashes[0].images[1].name", { $0.crashes[0].images[1].name = "Sample Plugin" }),
            ("crashes[0].exceptionType", { $0.crashes[0].exceptionType = String(repeating: "X", count: 65) }),
            (
                "events[3].p.trigger",
                { report in
                    guard case .object(var event) = report.events[3], case .object(var payload) = event["p"] else {
                        return
                    }
                    payload["trigger"] = .string("Weekly sync")
                    event["p"] = .object(payload)
                    report.events[3] = .object(event)
                }
            ),
        ]
        for (path, change) in cases {
            var report = try fixture()
            change(&report)
            #expect(DiagnosticReportValidator.violations(in: report) == [.token(path: path)], "\(path)")
            #expect(throws: DiagnosticReportViolation.token(path: path)) {
                try DiagnosticReportValidator.validate(report)
            }
        }

        // A key that breaks the rule is reported without repeating it.
        var report = try fixture()
        report.summary.settings["sample setting"] = .bool(true)
        #expect(DiagnosticReportValidator.violations(in: report) == [.token(path: "summary.settings.?")])
    }

    @Test("the note and contact are free text on a user report and refused on any other")
    func theNoteAndContactAreFreeTextOnAUserReportAndRefusedOnAnyOther() throws {
        var report = try fixture()
        report.note = "It stopped at 3pm / after \"the call\" with someone@example.com"
        report.contact = "Someone <someone@example.com>"
        #expect(DiagnosticReportValidator.violations(in: report).isEmpty)

        for kind in [DiagnosticReport.Kind.crash, .automatic] {
            report.kind = kind
            #expect(DiagnosticReportValidator.violations(in: report) == [.freeTextNotAllowed])
        }
        report.note = nil
        report.contact = nil
        #expect(DiagnosticReportValidator.violations(in: report).isEmpty)
    }

    @Test("the count and length limits are the server's")
    func theCountAndLengthLimitsAreTheServers() throws {
        let base = try fixture()

        var events = base
        events.events = Array(repeating: .object(["v": .integer(1)]), count: DiagnosticReportLimits.events + 1)
        #expect(DiagnosticReportValidator.violations(in: events) == [.tooManyEvents(20_001)])
        events.events = [.integer(1)]
        #expect(DiagnosticReportValidator.violations(in: events) == [.eventNotAnObject(index: 0)])

        var crashes = base
        crashes.crashes = Array(repeating: base.crashes[0], count: DiagnosticReportLimits.crashes + 1)
        #expect(DiagnosticReportValidator.violations(in: crashes) == [.tooManyCrashes(11)])

        var frames = base
        frames.crashes[0].frames = Array(repeating: .init(image: 0, offset: 1), count: 129)
        #expect(DiagnosticReportValidator.violations(in: frames) == [.tooManyFrames(crash: 0, count: 129)])

        var text = base
        text.note = String(repeating: "a", count: 4000)
        text.contact = String(repeating: "b", count: 254)
        #expect(DiagnosticReportValidator.violations(in: text).isEmpty)
        // Counted as the server counts, in UTF-16: each of these takes two.
        text.note = String(repeating: "\u{1F426}", count: 2001)
        text.contact = String(repeating: "b", count: 255)
        #expect(DiagnosticReportValidator.violations(in: text) == [.noteTooLong(4002), .contactTooLong(255)])

        var schema = base
        schema.schemaVersion = 2
        #expect(DiagnosticReportValidator.violations(in: schema) == [.unsupportedSchema(2)])
    }

    @Test("a reduced crash goes into a report that passes the checks")
    func aReducedCrashGoesIntoAReportThatPassesTheChecks() throws {
        var report = try fixture()
        report.kind = .crash
        report.note = nil
        report.contact = nil
        report.crashes = try ["pipit-crash", "older-layout"].map {
            try #require(CrashReportReducer.reduce(try DiagnosticsFixtures.data($0))).summary
        }
        #expect(DiagnosticReportValidator.violations(in: report).isEmpty)
        let text = try #require(String(data: try report.encoded(), encoding: .utf8))
        #expect(text.contains(#""occurredAt":"2026-10-21T10:18:16Z""#))
        // Which executable crashed travels with the summary.
        #expect(text.contains(#""process":"app""#))
        #expect(text.contains(#""process":"nativehost""#))
        #expect(!text.contains("CANARY"))
    }

    @Test("the token rule allows exactly its characters, up to 64 of them")
    func theTokenRuleAllowsExactlyItsCharactersUpTo64OfThem() {
        for accepted in [
            "", "A-Za-z0-9_.,:+#=-", "2026-10-21T03:18:16.123Z", "Mac15,3", "0.1.8-dev.abc1234", "SIGNAL.11",
            String(repeating: "x", count: 64),
        ] {
            #expect(DiagnosticTokenRule.accepts(accepted), "\(accepted)")
        }
        for refused in [
            " ", "a/b", "a@b", "\"", "'", "a\\b", "\u{E9}", "a\nb", "(", "~", "%", String(repeating: "x", count: 65),
        ] {
            #expect(!DiagnosticTokenRule.accepts(refused), "\(refused)")
            #expect(DiagnosticTokenRule.token(refused) == "invalid")
        }
    }
}
