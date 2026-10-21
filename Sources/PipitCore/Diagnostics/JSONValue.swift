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
    public static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
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
