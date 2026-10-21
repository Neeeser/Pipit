import Foundation

/// Any JSON document, held as a tree.
///
/// Diagnostics read two kinds of JSON they do not own the shape of: Apple's
/// crash reports, whose fields come and go between macOS releases, and event
/// lines already on disk, which a report carries through unchanged. Neither
/// fits a fixed `Codable` type, and `JSONSerialization` hands back `Any`,
/// which is neither `Sendable` nor comparable. Integers are kept apart from
/// doubles so a load address or a byte count survives a round trip exactly.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Parses one JSON document, or nil when the bytes are not one.
    ///
    /// Read byte by byte rather than through `JSONDecoder`. The decoder can
    /// only learn a value's type by trying each in turn, and every miss
    /// throws, so a report's twenty thousand event lines took seconds to
    /// read back for the token check. A number whose value is whole and fits
    /// is an integer, as it was through the decoder.
    public static func parse(_ data: Data) -> JSONValue? {
        data.withUnsafeBytes { raw in
            var parser = JSONTreeParser(bytes: raw.bindMemory(to: UInt8.self))
            return parser.document()
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    public var stringValue: String? {
        guard case .string(let text) = self else { return nil }
        return text
    }

    /// An integer, or a double with no fractional part that fits one.
    public var integerValue: Int64? {
        switch self {
        case .integer(let value): return value
        case .double(let value): return Int64(exactly: value)
        default: return nil
        }
    }

    /// A boolean, also read from the strings `"true"` and `"false"`, because
    /// crash reports have written some flags both ways.
    public var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .string("true"): return true
        case .string("false"): return false
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let elements) = self else { return nil }
        return elements
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let members) = self else { return nil }
        return members
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// The parser behind `JSONValue.parse`: RFC 8259, with fragments allowed at
/// the top level, as `JSONDecoder` allows them.
private struct JSONTreeParser {
    let bytes: UnsafeBufferPointer<UInt8>
    var index = 0
    var depth = 0

    /// Deeper than this is refused rather than recursed into. Nothing Pipit
    /// reads nests past a dozen levels.
    static let maximumDepth = 512

    init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    mutating func document() -> JSONValue? {
        guard let value = value() else { return nil }
        skipWhitespace()
        return index == bytes.count ? value : nil
    }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { index += 1 }
    }

    private mutating func value() -> JSONValue? {
        skipWhitespace()
        guard let byte = current else { return nil }
        switch byte {
        case UInt8(ascii: "{"): return object()
        case UInt8(ascii: "["): return array()
        case UInt8(ascii: "\""): return string().map(JSONValue.string)
        case UInt8(ascii: "t"): return literal("true", .bool(true))
        case UInt8(ascii: "f"): return literal("false", .bool(false))
        case UInt8(ascii: "n"): return literal("null", .null)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return number()
        default: return nil
        }
    }

    private mutating func literal(_ text: StaticString, _ value: JSONValue) -> JSONValue? {
        let count = text.utf8CodeUnitCount
        guard index + count <= bytes.count else { return nil }
        for offset in 0..<count where bytes[index + offset] != text.utf8Start[offset] { return nil }
        index += count
        return value
    }

    private mutating func object() -> JSONValue? {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maximumDepth else { return nil }
        index += 1
        var members: [String: JSONValue] = [:]
        skipWhitespace()
        if current == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard current == UInt8(ascii: "\""), let key = string() else { return nil }
            skipWhitespace()
            guard current == UInt8(ascii: ":") else { return nil }
            index += 1
            guard let member = value() else { return nil }
            members[key] = member
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "}"):
                index += 1
                return .object(members)
            default: return nil
            }
        }
    }

    private mutating func array() -> JSONValue? {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maximumDepth else { return nil }
        index += 1
        var elements: [JSONValue] = []
        skipWhitespace()
        if current == UInt8(ascii: "]") {
            index += 1
            return .array(elements)
        }
        while true {
            guard let element = value() else { return nil }
            elements.append(element)
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "]"):
                index += 1
                return .array(elements)
            default: return nil
            }
        }
    }

    /// A string, the opening quote at `index`.
    private mutating func string() -> String? {
        index += 1
        let start = index
        // The common case: no escapes, read as one run.
        while let byte = current, byte != UInt8(ascii: "\""), byte != UInt8(ascii: "\\") {
            guard byte >= 0x20 else { return nil }
            index += 1
        }
        guard let stop = current else { return nil }
        var scalars = [UInt8](bytes[start..<index])
        if stop == UInt8(ascii: "\"") {
            index += 1
            return String(validating: scalars, as: UTF8.self)
        }
        while let byte = current {
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(validating: scalars, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard let unescaped = escape() else { return nil }
                scalars.append(contentsOf: unescaped)
            default:
                guard byte >= 0x20 else { return nil }
                scalars.append(byte)
            }
        }
        return nil
    }

    /// The UTF-8 an escape stands for, its backslash already read.
    private mutating func escape() -> [UInt8]? {
        guard let escaped = current else { return nil }
        index += 1
        switch escaped {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): return [escaped]
        case UInt8(ascii: "b"): return [0x08]
        case UInt8(ascii: "f"): return [0x0C]
        case UInt8(ascii: "n"): return [0x0A]
        case UInt8(ascii: "r"): return [0x0D]
        case UInt8(ascii: "t"): return [0x09]
        case UInt8(ascii: "u"): return unicodeEscape().map { Array(String(Character($0)).utf8) }
        default: return nil
        }
    }

    /// The scalar of a `\u` escape, its `u` already read, joining a
    /// surrogate pair. A lone surrogate is refused.
    private mutating func unicodeEscape() -> Unicode.Scalar? {
        guard let first = hex4() else { return nil }
        switch first {
        case 0xD800...0xDBFF:
            guard current == UInt8(ascii: "\\"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "u")
            else { return nil }
            index += 2
            guard let second = hex4(), (0xDC00...0xDFFF).contains(second) else { return nil }
            return Unicode.Scalar(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00))
        case 0xDC00...0xDFFF:
            return nil
        default:
            return Unicode.Scalar(first)
        }
    }

    private mutating func hex4() -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: return nil
            }
            value = value << 4 | UInt32(digit)
            index += 1
        }
        return value
    }

    private mutating func number() -> JSONValue? {
        let start = index
        var isInteger = true
        if current == UInt8(ascii: "-") { index += 1 }
        guard let lead = current, Self.isDigit(lead) else { return nil }
        if lead == UInt8(ascii: "0") {
            index += 1
        } else {
            skipDigits()
        }
        if current == UInt8(ascii: ".") {
            isInteger = false
            index += 1
            guard let digit = current, Self.isDigit(digit) else { return nil }
            skipDigits()
        }
        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            isInteger = false
            index += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
            guard let digit = current, Self.isDigit(digit) else { return nil }
            skipDigits()
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if isInteger, let integer = Int64(text) { return .integer(integer) }
        guard let double = Double(text), double.isFinite else { return nil }
        // `JSONDecoder` reads `2.5e3` as the integer 2500, and so does this.
        if let integer = Int64(exactly: double) { return .integer(integer) }
        return .double(double)
    }

    private mutating func skipDigits() {
        while let byte = current, Self.isDigit(byte) { index += 1 }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}
