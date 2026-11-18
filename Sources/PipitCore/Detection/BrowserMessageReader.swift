import Foundation

/// Reads the browser's length-prefixed native-messaging frames.
///
/// Browser stdin speaks a 4-byte little-endian length followed by that many
/// bytes of JSON. The host reads it on its main thread for as long as the
/// browser keeps the port open, which is days.
public struct BrowserMessageReader {
    /// Returns up to `count` bytes, or empty data once the stream ends.
    public typealias Read = (_ count: Int) -> Data

    private let read: Read
    /// Why reading stopped: the browser closed the pipe, or sent something
    /// that is not a message.
    public private(set) var endedOnError = false

    public init(read: @escaping Read = { FileHandle.standardInput.readData(ofLength: $0) }) {
        self.read = read
    }

    /// Reads exactly `count` bytes, or nil once the stream ends.
    private func readExactly(_ count: Int) -> Data? {
        var data = Data()
        while data.count < count {
            let chunk = read(count - data.count)
            if chunk.isEmpty { return nil }
            data.append(chunk)
        }
        return data
    }

    public mutating func next() -> [String: Any]? {
        guard let header = readExactly(4) else { return nil }
        let length =
            Int(header[header.startIndex])
            | Int(header[header.startIndex + 1]) << 8
            | Int(header[header.startIndex + 2]) << 16
            | Int(header[header.startIndex + 3]) << 24
        // A hostile or confused peer must not be able to make the host allocate
        // without bound; browsers cap messages far below this.
        guard length > 0, length <= 1_048_576 else {
            endedOnError = true
            return nil
        }
        guard let payload = readExactly(length) else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            endedOnError = true
            return nil
        }
        return object
    }

    /// Hands each message to `handle` until the stream ends, and returns
    /// whether it ended on something that was not a message.
    ///
    /// Each message is read and handled inside its own autorelease pool.
    /// `FileHandle.readData` and `JSONSerialization` return autoreleased
    /// objects, and a loop on the main thread never returns to a run loop
    /// that would drain them, so without the pool every message the browser
    /// ever sent stayed in memory: a host left running for two days held
    /// 50,000 buffers and 409 MB.
    public mutating func readAll(_ handle: ([String: Any]) -> Void) -> Bool {
        while true {
            let more = autoreleasepool { () -> Bool in
                guard let raw = next() else { return false }
                handle(raw)
                return true
            }
            if !more { return endedOnError }
        }
    }
}
