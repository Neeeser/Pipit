import Foundation
import PipitCore
import Testing

@Suite("FileIdentity")
struct FileIdentityTests {
    private func makeFile(_ contents: String) throws -> URL {
        let url = try TestPaths.makeTemporaryDirectory().appendingPathComponent("pipit-nativehost")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test("a file left alone is the same file")
    func aFileLeftAloneIsTheSameFile() throws {
        let url = try makeFile("build one")
        let identity = try #require(FileIdentity(path: url.path))
        #expect(!identity.isReplaced(at: url.path))
    }

    @Test("a reinstall that removes and copies the file is a replacement")
    func aReinstallIsAReplacement() throws {
        let url = try makeFile("build one")
        let identity = try #require(FileIdentity(path: url.path))
        let incoming = url.deletingLastPathComponent().appendingPathComponent("incoming")
        try Data("build two".utf8).write(to: incoming)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: incoming, to: url)
        #expect(identity.isReplaced(at: url.path))
    }

    @Test("a file rewritten in place is a replacement")
    func aFileRewrittenInPlaceIsAReplacement() throws {
        let url = try makeFile("build one")
        let identity = try #require(FileIdentity(path: url.path))
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data("build two, longer".utf8))
        try handle.close()
        #expect(identity.isReplaced(at: url.path))
    }

    @Test("a removed file is a replacement")
    func aRemovedFileIsAReplacement() throws {
        let url = try makeFile("build one")
        let identity = try #require(FileIdentity(path: url.path))
        try FileManager.default.removeItem(at: url)
        #expect(identity.isReplaced(at: url.path))
        #expect(FileIdentity(path: url.path) == nil)
    }
}
