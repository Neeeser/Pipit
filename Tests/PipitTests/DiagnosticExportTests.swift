import Foundation
import Testing

@testable import PipitCore

/// The `.zip` that Export Diagnostics saves.
@Suite("Diagnostic export")
struct DiagnosticExportTests {
    @Test("the archive holds the readable report, the exact upload body and a README")
    func theArchiveHoldsTheReadableReportTheExactUploadBodyAndAREADME() throws {
        let bundle = try DiagnosticBundleBuilder.build(
            try DiagnosticBundleTests.contents(events: DiagnosticBundleTests.events(5)),
            request: DiagnosticBundleTests.request()
        )
        #expect(
            DiagnosticExport.fileName(createdAt: bundle.report.createdAt) == "Pipit-Diagnostics-20261021T031816Z.zip")

        let entries = try DiagnosticArchive.read(try DiagnosticExport.archive(bundle))
        #expect(
            entries.map(\.name) == [
                "Pipit-Diagnostics-20261021T031816Z/report.json",
                "Pipit-Diagnostics-20261021T031816Z/report.json.gz",
                "Pipit-Diagnostics-20261021T031816Z/README.txt",
            ]
        )
        let pretty = entries[0].contents
        #expect(String(data: pretty, encoding: .utf8)?.contains("\n  \"app\" : {") == true)
        #expect(try DiagnosticReport.decode(pretty) == bundle.report)
        #expect(entries[1].contents == bundle.gzipped)
        #expect(try DiagnosticCompression.gunzip(entries[1].contents) == bundle.json)
        let readme = String(decoding: entries[2].contents, as: UTF8.self)
        for section in ["app", "system", "summary", "events", "crashes", "Never included"] {
            #expect(readme.contains(section), "\(section)")
        }
        // No note or contact unless the person typed them.
        #expect(bundle.report.note == nil)
        #expect(!String(decoding: pretty, as: UTF8.self).contains("\"note\""))
    }

    @Test("the archive is a ZIP other tools read")
    func theArchiveIsAZIPOtherToolsRead() throws {
        let archive = DiagnosticArchive(
            entries: [
                .init(name: "folder/a.txt", contents: Data("first\n".utf8)),
                .init(name: "folder/empty", contents: Data()),
                .init(name: "folder/b.bin", contents: Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0) })),
            ],
            modified: DiagnosticBundleTests.created
        )
        let data = try archive.data()
        #expect(Array(data.prefix(4)) == [0x50, 0x4B, 0x03, 0x04])
        #expect(try DiagnosticArchive.read(data) == archive.entries)

        // Where the system's unzip exists, it agrees.
        let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
        guard FileManager.default.isExecutableFile(atPath: unzip.path) else { return }
        let directory = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("archive.zip")
        try data.write(to: file)
        let process = Process()
        process.executableURL = unzip
        process.arguments = ["-q", file.path, "-d", directory.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try Data(contentsOf: directory.appendingPathComponent("folder/a.txt")) == Data("first\n".utf8))
        #expect(try Data(contentsOf: directory.appendingPathComponent("folder/b.bin")) == archive.entries[2].contents)
    }

    @Test("a DOS time is the local wall clock, from 1980")
    func aDOSTimeIsTheLocalWallClockFrom1980() {
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 3, minute: 18, second: 17))
        let (time, day) = DiagnosticArchive.dosTime(date ?? Date())
        #expect(time == (3 << 11 | 18 << 5 | 8))
        #expect(day == ((2026 - 1980) << 9 | 10 << 5 | 21))
    }
}
