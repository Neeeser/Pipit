import Foundation

/// A 16 kHz mono float WAV that is appended to while a meeting records and
/// can be read at any point.
///
/// The header is rewritten with the current length before each read, so a
/// reader sees a complete file of everything appended so far, while the writer
/// keeps appending after it. Scratch only: the recording itself is the
/// segment files.
public final class GrowingWaveFile {
    public let url: URL
    private let handle: FileHandle
    private var dataBytes: UInt32 = 0
    private static let headerBytes: UInt64 = 44

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: Self.header(dataBytes: 0))
        handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    /// Seconds of audio appended so far.
    public var seconds: Double { Double(dataBytes) / 4 / LiveTrackResampler.sampleRate }

    public func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        dataBytes &+= UInt32(data.count)
    }

    /// Makes the header describe everything appended so far.
    public func seal() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataBytes: dataBytes))
        try handle.seekToEnd()
    }

    private static func header(dataBytes: UInt32) -> Data {
        var data = Data()
        func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(LiveTrackResampler.sampleRate)
        data.append(contentsOf: Array("RIFF".utf8))
        put(36 &+ dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        put(UInt32(16))
        put(UInt16(3))  // IEEE float
        put(UInt16(1))
        put(rate)
        put(rate * 4)
        put(UInt16(4))
        put(UInt16(32))
        data.append(contentsOf: Array("data".utf8))
        put(dataBytes)
        return data
    }
}
