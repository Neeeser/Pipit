import Foundation

/// A JSON object whose keys are written in the order given.
///
/// A model held to a schema writes the fields in the order the schema lists
/// them, and the summary prompt relies on that: the topics come first so the
/// overview is written after the model has walked the meeting. A dictionary
/// would serialize in whatever order it hashes to.
struct OrderedJSONObject {
    var pairs: [(String, Any)]

    init(_ pairs: [(String, Any)]) {
        self.pairs = pairs
    }
}

/// Serializes a request body that may hold `OrderedJSONObject` values.
///
/// Plain dictionaries are written with sorted keys, so a body is the same bytes
/// every time it is built.
enum RequestJSON {
    static func data(_ value: Any) throws -> Data {
        var text = ""
        try write(value, into: &text)
        return Data(text.utf8)
    }

    static func string(_ value: Any) -> String {
        (try? data(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func write(_ value: Any, into text: inout String) throws {
        switch value {
        case let object as OrderedJSONObject:
            try writeObject(object.pairs, into: &text)
        case let dictionary as [String: Any]:
            try writeObject(dictionary.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, into: &text)
        case let array as [Any]:
            text += "["
            for (index, element) in array.enumerated() {
                if index > 0 { text += "," }
                try write(element, into: &text)
            }
            text += "]"
        default:
            // Strings, numbers, booleans and null: Foundation knows how to
            // escape and spell each, including a boolean held in an NSNumber.
            let leaf = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            text += String(bytes: leaf, encoding: .utf8) ?? ""
        }
    }

    private static func writeObject(_ pairs: [(String, Any)], into text: inout String) throws {
        text += "{"
        for (index, pair) in pairs.enumerated() {
            if index > 0 { text += "," }
            try write(pair.0, into: &text)
            text += ":"
            try write(pair.1, into: &text)
        }
        text += "}"
    }
}
