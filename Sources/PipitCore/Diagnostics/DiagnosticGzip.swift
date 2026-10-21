import Foundation

/// gzip (RFC 1952), the encoding a report is sent in (`docs/DIAGNOSTICS.md`,
/// Report format).
///
/// The header carries no file name and a zero modification time, so the same
/// JSON always frames the same way. The DEFLATE data inside is the system
/// compressor's on macOS. Elsewhere, where the command line harness builds
/// this module, the data is stored uncompressed in DEFLATE's stored blocks,
/// which every gzip reader accepts.
public enum DiagnosticGzip {
    public static func compress(_ data: Data) -> Data {
        frame(deflated: deflate(data), original: data)
    }

    /// Raw DEFLATE (RFC 1951). Foundation's `zlib` algorithm is raw DEFLATE
    /// without the zlib header, which is what gzip wraps.
    static func deflate(_ data: Data) -> Data {
        #if canImport(Darwin)
            if !data.isEmpty, let compressed = try? (data as NSData).compressed(using: .zlib) as Data {
                return compressed
            }
        #endif
        return stored(data)
    }

    /// DEFLATE stored blocks: each at most 65,535 bytes, the last one flagged
    /// final. Empty input is one empty final block.
    static func stored(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var output = Data()
        output.reserveCapacity(bytes.count + (bytes.count / 65_535 + 1) * 5)
        var offset = 0
        repeat {
            let count = min(65_535, bytes.count - offset)
            let isFinal = offset + count == bytes.count
            output.append(isFinal ? 1 : 0)
            let length = UInt16(count)
            let complement = ~length
            output.append(contentsOf: [
                UInt8(length & 0xff), UInt8(length >> 8), UInt8(complement & 0xff), UInt8(complement >> 8),
            ])
            output.append(contentsOf: bytes[offset..<(offset + count)])
            offset += count
        } while offset < bytes.count
        return output
    }

    /// The gzip header, the DEFLATE data, and the trailer: the CRC-32 and the
    /// length of the original, both little-endian.
    static func frame(deflated: Data, original: Data) -> Data {
        // ID1 ID2, CM = deflate, no flags, MTIME 0, XFL 0, OS unknown.
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        output.append(deflated)
        appendLittleEndian(crc32(original), to: &output)
        appendLittleEndian(UInt32(truncatingIfNeeded: original.count), to: &output)
        return output
    }

    /// CRC-32 as gzip uses it (reflected, polynomial 0xEDB88320).
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xffff_ffff
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xedb8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [
            UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8(value >> 24),
        ])
    }
}
