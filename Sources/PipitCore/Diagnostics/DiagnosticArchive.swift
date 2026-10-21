import Foundation

/// A ZIP file built in memory, for **Export Diagnostics**.
///
/// Written here rather than by `ditto` or by a coordinated read with
/// `.forUploading`, which zips a folder for free: the first runs a process for
/// three small files, and the second needs the folder on disk first and
/// behaves differently between macOS releases. The format needed is small:
/// DEFLATE entries, a central directory, and UTF-8 names. No ZIP64, which
/// a diagnostic bundle is far too small to need, no encryption, and no
/// extra fields.
public struct DiagnosticArchive: Sendable {
    public struct Entry: Sendable, Equatable {
        /// The path inside the archive, `/`-separated.
        public var name: String
        public var contents: Data

        public init(name: String, contents: Data) {
            self.name = name
            self.contents = contents
        }
    }

    public var entries: [Entry]
    /// The time every entry carries, in the archive's local DOS form.
    public var modified: Date

    public init(entries: [Entry], modified: Date) {
        self.entries = entries
        self.modified = modified
    }

    /// The archive's bytes.
    public func data() throws -> Data {
        var output = Data()
        var directory = Data()
        let (time, date) = Self.dosTime(modified)
        for entry in entries {
            let name = Data(entry.name.utf8)
            let compressed = try DiagnosticCompression.deflateRaw(entry.contents)
            let crc = DiagnosticCompression.crc32(entry.contents)
            guard output.count < Int(UInt32.max), compressed.count < Int(UInt32.max),
                entry.contents.count < Int(UInt32.max), name.count < Int(UInt16.max)
            else { throw DiagnosticCompression.Failure.tooLarge }
            let offset = UInt32(output.count)

            var local = Data()
            local.append(le32: 0x0403_4B50)
            local.append(le16: Self.versionNeeded)
            local.append(le16: Self.utf8Names)
            local.append(le16: Self.deflated)
            local.append(le16: time)
            local.append(le16: date)
            local.append(le32: crc)
            local.append(le32: UInt32(compressed.count))
            local.append(le32: UInt32(entry.contents.count))
            local.append(le16: UInt16(name.count))
            local.append(le16: 0)
            local.append(name)
            output.append(local)
            output.append(compressed)

            directory.append(le32: 0x0201_4B50)
            // Made by Unix, so the permissions below are read.
            directory.append(le16: 0x0300 | Self.versionNeeded)
            directory.append(le16: Self.versionNeeded)
            directory.append(le16: Self.utf8Names)
            directory.append(le16: Self.deflated)
            directory.append(le16: time)
            directory.append(le16: date)
            directory.append(le32: crc)
            directory.append(le32: UInt32(compressed.count))
            directory.append(le32: UInt32(entry.contents.count))
            directory.append(le16: UInt16(name.count))
            directory.append(le16: 0)  // extra
            directory.append(le16: 0)  // comment
            directory.append(le16: 0)  // disk
            directory.append(le16: 0)  // internal attributes
            directory.append(le32: UInt32(0o100_644) << 16)  // a regular file, rw-r--r--
            directory.append(le32: offset)
            directory.append(name)
        }
        guard output.count < Int(UInt32.max), entries.count < Int(UInt16.max) else {
            throw DiagnosticCompression.Failure.tooLarge
        }
        let directoryOffset = UInt32(output.count)
        output.append(directory)
        output.append(le32: 0x0605_4B50)
        output.append(le16: 0)
        output.append(le16: 0)
        output.append(le16: UInt16(entries.count))
        output.append(le16: UInt16(entries.count))
        output.append(le32: UInt32(directory.count))
        output.append(le32: directoryOffset)
        output.append(le16: 0)
        return output
    }

    /// The entries of an archive this type wrote, in order. Used by the tests
    /// to read an export back; it reads only what `data()` writes.
    static func read(_ archive: Data) throws -> [Entry] {
        let bytes = [UInt8](archive)
        guard bytes.count >= 22 else { throw DiagnosticCompression.Failure.corrupt }
        let end = bytes.count - 22
        guard bytes.le32(at: end) == 0x0605_4B50 else { throw DiagnosticCompression.Failure.corrupt }
        let count = Int(bytes.le16(at: end + 10))
        var cursor = Int(bytes.le32(at: end + 16))
        var entries: [Entry] = []
        for _ in 0..<count {
            guard cursor + 46 <= bytes.count, bytes.le32(at: cursor) == 0x0201_4B50 else {
                throw DiagnosticCompression.Failure.corrupt
            }
            let method = bytes.le16(at: cursor + 10)
            let crc = bytes.le32(at: cursor + 16)
            let compressedSize = Int(bytes.le32(at: cursor + 20))
            let nameLength = Int(bytes.le16(at: cursor + 28))
            let extraLength = Int(bytes.le16(at: cursor + 30))
            let commentLength = Int(bytes.le16(at: cursor + 32))
            let local = Int(bytes.le32(at: cursor + 42))
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            let localName = Int(bytes.le16(at: local + 26))
            let localExtra = Int(bytes.le16(at: local + 28))
            let start = local + 30 + localName + localExtra
            guard start + compressedSize <= bytes.count else { throw DiagnosticCompression.Failure.corrupt }
            let stored = Data(bytes[start..<(start + compressedSize)])
            let contents = method == Self.deflated ? try DiagnosticCompression.inflateRaw(stored) : stored
            guard DiagnosticCompression.crc32(contents) == crc else { throw DiagnosticCompression.Failure.corrupt }
            entries.append(Entry(name: name, contents: contents))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    // MARK: - format

    /// 2.0, the version that introduced DEFLATE.
    private static let versionNeeded: UInt16 = 20
    /// General purpose bit 11: names are UTF-8.
    private static let utf8Names: UInt16 = 0x0800
    private static let deflated: UInt16 = 8

    /// MS-DOS time and date, in the Mac's own time zone, which is what the
    /// Finder shows an entry's date in. Clamped to 1980, the format's epoch.
    static func dosTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(0, min(127, (parts.year ?? 1980) - 1980))
        let time = ((parts.hour ?? 0) << 11) | ((parts.minute ?? 0) << 5) | ((parts.second ?? 0) / 2)
        let day = (year << 9) | ((parts.month ?? 1) << 5) | (parts.day ?? 1)
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: day))
    }
}

extension Data {
    fileprivate mutating func append(le16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    fileprivate mutating func append(le32 value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }
}

extension [UInt8] {
    fileprivate func le16(at index: Int) -> UInt16 {
        guard index + 2 <= count else { return 0 }
        return UInt16(self[index]) | UInt16(self[index + 1]) << 8
    }

    fileprivate func le32(at index: Int) -> UInt32 {
        guard index + 4 <= count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[index + $1]) << UInt32($1 * 8) }
    }
}
