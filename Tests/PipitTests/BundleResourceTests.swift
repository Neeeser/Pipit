import Foundation
import Testing

@Suite("Bundle resources")
struct BundleResourceTests {
    private struct Result {
        var status: Int32
        var output: String
    }

    private func locate(in bundle: URL) throws -> Result {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/echo-models-path.sh")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, bundle.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            output: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    @Test(
        "the bundler finds models in either SwiftPM resource layout",
        arguments: ["EchoModels", "Contents/Resources/EchoModels"])
    func findsModels(_ relativePath: String) throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let models = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let result = try locate(in: root)
        #expect(result.status == 0)
        #expect(result.output == models.path + "\n")
    }

    @Test("missing models stop packaging")
    func missingModelsFail() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try locate(in: root)
        #expect(result.status == 1)
        #expect(result.output.isEmpty)
    }
}
