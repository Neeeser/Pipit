import Foundation
import zlib

/// Gzip and raw DEFLATE for diagnostic reports, through the system's zlib.
///
/// A report is sent with `Content-Encoding: gzip`, so the body needs the gzip
/// header and trailer. The Compression framework and `NSData.compressed` write
/// raw DEFLATE only, and neither exists on Linux, where the pure diagnostics
/// code is also tested. zlib writes the gzip wrapper itself when
/// `deflateInit2` is given a window of 31 bits (15, plus 16 for gzip), and
/// ships in every macOS SDK as the `zlib` module.
public enum DiagnosticCompression {
    public enum Failure: Error, Equatable, Sendable {
        /// zlib refused to start, or stopped with this status.
        case zlib(Int32)
        /// The input is larger than one zlib call takes. A report never is.
        case tooLarge
        /// The data is not what it was read as.
        case corrupt
    }

    /// The gzip container: zlib's 15-bit window plus 16.
    static let gzipWindowBits: Int32 = 31
    /// Raw DEFLATE, as a ZIP entry stores it.
    static let rawWindowBits: Int32 = -15

    /// `data` compressed as one gzip member, at the best compression level.
    ///
    /// The header carries no file name and no time, so the same input gives
    /// the same bytes on the same zlib, which is what lets a retry send the
    /// body it stored.
    public static func gzip(_ data: Data) throws -> Data {
        try deflate(data, windowBits: gzipWindowBits)
    }

    /// The bytes of a gzip member, or a zlib stream with `gzip` false.
    public static func gunzip(_ data: Data) throws -> Data {
        try inflate(data, windowBits: gzipWindowBits)
    }

    /// Raw DEFLATE with no header, for a ZIP entry.
    static func deflateRaw(_ data: Data) throws -> Data {
        try deflate(data, windowBits: rawWindowBits)
    }

    static func inflateRaw(_ data: Data) throws -> Data {
        try inflate(data, windowBits: rawWindowBits)
    }

    /// The CRC-32 a gzip trailer and a ZIP entry both carry.
    static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw -> UInt32 in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return 0 }
            return UInt32(truncatingIfNeeded: zlib.crc32(0, base, uInt(raw.count)))
        }
    }

    // MARK: - zlib

    private static let chunk = 64 * 1_024

    private static func deflate(_ data: Data, windowBits: Int32) throws -> Data {
        guard data.count < Int(UInt32.max) else { throw Failure.tooLarge }
        var stream = z_stream()
        let started = deflateInit2_(
            &stream, Z_BEST_COMPRESSION, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard started == Z_OK else { throw Failure.zlib(started) }
        defer { deflateEnd(&stream) }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: chunk)
        var status = Z_OK
        data.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(raw.count)
            repeat {
                buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    status = zlib.deflate(&stream, Z_FINISH)
                    if let base = out.baseAddress { output.append(base, count: out.count - Int(stream.avail_out)) }
                }
            } while status == Z_OK
        }
        guard status == Z_STREAM_END else { throw Failure.zlib(status) }
        return output
    }

    private static func inflate(_ data: Data, windowBits: Int32) throws -> Data {
        guard data.count < Int(UInt32.max) else { throw Failure.tooLarge }
        var stream = z_stream()
        let started = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard started == Z_OK else { throw Failure.zlib(started) }
        defer { inflateEnd(&stream) }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: chunk)
        var status = Z_OK
        data.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(raw.count)
            repeat {
                buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    if let base = out.baseAddress { output.append(base, count: out.count - Int(stream.avail_out)) }
                }
                // Input that ends before the stream does leaves zlib asking
                // for more with nothing left to give.
                if status == Z_OK, stream.avail_in == 0, stream.avail_out != 0 { status = Z_BUF_ERROR }
            } while status == Z_OK
        }
        guard status == Z_STREAM_END else { throw Failure.corrupt }
        return output
    }
}
