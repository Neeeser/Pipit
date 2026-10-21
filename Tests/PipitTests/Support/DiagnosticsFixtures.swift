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
}
