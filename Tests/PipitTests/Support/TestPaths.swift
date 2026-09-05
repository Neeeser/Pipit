import Foundation

/// Scratch locations for tests. The `pipit-tests-` prefix is what
/// `scripts/check-offline.sh` looks for when it checks that a run wrote only
/// under the temporary directory.
public enum TestPaths {
    public static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
