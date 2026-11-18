import Darwin
import Foundation
import PipitCore
import Testing

/// The native host's read loop, which runs for as long as a browser stays open.
struct BrowserMessageReaderTests {
    /// Frames `count` copies of a small message the way a browser does.
    private static func frames(count: Int) -> Data {
        let payload = Data(#"{"type":"state","provider":"meet","state":"browsing","tabId":7}"#.utf8)
        var length = UInt32(payload.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        var all = Data()
        for _ in 0..<count { all.append(frame) }
        return all
    }

    private static func bytesInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats.size_in_use
    }

    @Test("reading messages from a pipe for days does not keep each one in memory")
    func readingMessagesDoesNotKeepEachOneInMemory() throws {
        let count = 3_000
        let pipe = Pipe()
        let input = Self.frames(count: count)
        // A browser writes while the host reads; the pipe holds far less
        // than the whole stream.
        let writer = Thread {
            pipe.fileHandleForWriting.write(input)
            try? pipe.fileHandleForWriting.close()
        }
        writer.start()

        let handle = pipe.fileHandleForReading
        var reader = BrowserMessageReader(read: { handle.readData(ofLength: $0) })
        var seen = 0
        let before = Self.bytesInUse()
        let endedOnError = reader.readAll { raw in
            if raw["type"] as? String == "state" { seen += 1 }
        }
        let growth = Self.bytesInUse() - before

        #expect(seen == count)
        #expect(endedOnError == false)
        // Each message left two 8 KB read buffers and its parsed dictionary
        // behind before the loop drained its pool, about 50 MB for this many.
        #expect(growth < 4_000_000, "grew \(growth) bytes over \(count) messages")
    }

    @Test("a frame longer than the cap ends reading as an error")
    func aFrameLongerThanTheCapEndsReadingAsAnError() {
        var length = UInt32(2_000_000).littleEndian
        var stream = Data(bytes: &length, count: 4)
        stream.append(Data(repeating: 0x20, count: 16))
        var offset = 0
        var reader = BrowserMessageReader(read: { count in
            let end = min(offset + count, stream.count)
            defer { offset = end }
            return stream.subdata(in: offset..<end)
        })
        var seen = 0
        #expect(reader.readAll { _ in seen += 1 } == true)
        #expect(seen == 0)
    }
}
