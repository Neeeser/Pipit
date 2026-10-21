import Foundation
import PipitCore
import Testing

/// The synthetic crash reports and diagnostic report under
/// `Tests/Fixtures/Diagnostics`. They sit outside the test target's folder,
/// so SwiftPM needs no resource declaration, and are read from the source
/// tree. Every report is invented: the `CANARY` strings stand where a real
/// report carries a name, a title, or a path, and no reduction may keep one.
enum DiagnosticsFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // PipitTests
        .deletingLastPathComponent()  // Tests
        .appendingPathComponent("Fixtures/Diagnostics", isDirectory: true)

    static let report = directory.appendingPathComponent("report-v1.json")

    static func ips(_ name: String) -> URL {
        directory.appendingPathComponent("ips/\(name).ips")
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: ips(name))
    }

    /// The parts of `pipit-crash.ips`, for a test that builds a variant.
    static func parts(_ name: String) throws -> (header: [String: Any], body: [String: Any]) {
        let text = try #require(String(data: try data(name), encoding: .utf8))
        let newline = try #require(text.firstIndex(of: "\n"))
        let header = try JSONSerialization.jsonObject(with: Data(text[..<newline].utf8))
        let body = try JSONSerialization.jsonObject(with: Data(text[text.index(after: newline)...].utf8))
        return (try #require(header as? [String: Any]), try #require(body as? [String: Any]))
    }

    /// An `.ips` written the way ReportCrash writes one: the header on one
    /// line, the report after it.
    static func ipsData(header: [String: Any], body: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: header)
        data.append(UInt8(ascii: "\n"))
        data.append(try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted]))
        return data
    }

    /// The UTC instant ReportCrash's local times in the fixtures stand for.
    static func utc(_ text: String) -> Date {
        guard let date = DiagnosticCoding.date(from: text) else {
            preconditionFailure("not an ISO 8601 time: \(text)")
        }
        return date
    }

    /// The launch record `pipit-crash.ips` belongs to: pid 4242, started at
    /// the report's `procLaunch`, on boot A.
    static func crashedLaunch(clean: Bool = false, bootSession: String? = bootA) -> LaunchRecord {
        LaunchRecord(
            launch: "0f6e2a1b-3c4d-4e5f-8a9b-0c1d2e3f4a5b", pid: 4242,
            startedAt: utc("2026-10-21T10:10:00.5Z"), bootSession: bootSession,
            binaryUUID: "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", version: "0.1.8", clean: clean
        )
    }

    static let bootA = "5a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d"
    static let bootB = "6b7c8d9e-0f1a-4b2c-9d3e-4f5a6b7c8d9e"
}
