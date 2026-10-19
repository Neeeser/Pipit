import Foundation

/// Reads the JSON object out of a model's reply.
///
/// A model asked for JSON may wrap it in a code fence, put a line of prose in
/// front of it, or think out loud first. Models served from a local machine do
/// all three, so the reply is searched for the object rather than required to
/// be one.
enum ModelJSON {
    static func object(from reply: String) -> [String: Any]? {
        let text = withoutReasoning(reply)
        if let object = parse(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return object }

        // Each opening brace is tried in turn, so prose that mentions a brace
        // before the object does not hide the object. Bounded, because a reply
        // that is all braces is not going to improve.
        var from = text.startIndex
        for _ in 0..<64 {
            guard let open = text[from...].firstIndex(of: "{") else { return nil }
            if let close = closingBrace(matching: open, in: text),
                let object = parse(String(text[open...close]))
            {
                return object
            }
            from = text.index(after: open)
        }
        return nil
    }

    /// The reply after a reasoning model's thinking, which some servers leave
    /// inline between think tags.
    private static func withoutReasoning(_ reply: String) -> String {
        guard let end = reply.range(of: "</think>", options: .backwards) else { return reply }
        return String(reply[end.upperBound...])
    }

    private static func parse(_ text: String) -> [String: Any]? {
        guard !text.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func closingBrace(matching open: String.Index, in text: String) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
