import Foundation

/// The rule every string in a diagnostic report keeps, except the person's
/// own note and contact address: `^[A-Za-z0-9_.,:+#=-]{0,64}$`.
///
/// It is a second line of defence behind the allowlist. A title, a name, a
/// path, a URL, or an email address needs a space, a slash, an `@`, or a
/// quote, and none of those pass. The report service rejects a report that
/// breaks it, and the app checks the same rule before export or send, so a
/// report the app would send is one the server accepts.
public enum DiagnosticTokenRule {
    public static let maximumLength = 64

    /// The value a field takes when what was read from outside Pipit fails
    /// the rule.
    public static let invalid = "invalid"

    public static func accepts(_ text: String) -> Bool {
        var count = 0
        for scalar in text.unicodeScalars {
            count += 1
            guard count <= maximumLength, isAllowed(scalar) else { return false }
        }
        return true
    }

    /// `text` when it passes, `invalid` when it does not.
    public static func token(_ text: String) -> String {
        accepts(text) ? text : invalid
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9": true
        case "_", ".", ",", ":", "+", "#", "=", "-": true
        default: false
        }
    }
}

/// JSON coding for diagnostic files and reports.
///
/// A report writes whole seconds, as the contract's examples do. The files
/// under `~/Library/Logs/Pipit/` keep fractions, because a launch time is
/// matched against the launch time a crash report gives to the millisecond.
/// Either form is read back.
public enum DiagnosticCoding {
    private static let wholeSeconds = Date.ISO8601FormatStyle()
    private static let fractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public static func string(from date: Date) -> String { wholeSeconds.format(date) }

    public static func date(from text: String) -> Date? {
        if let parsed = try? wholeSeconds.parse(text) { return parsed }
        return try? fractionalSeconds.parse(text)
    }

    /// The encoder a report is written with.
    public static func makeReportEncoder() -> JSONEncoder {
        makeEncoder(style: wholeSeconds)
    }

    /// The encoder `state/launch.json` and `crashes/` are written with.
    public static func makeFileEncoder() -> JSONEncoder {
        let encoder = makeEncoder(style: fractionalSeconds)
        encoder.outputFormatting.insert(.prettyPrinted)
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let parsed = date(from: text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 time")
                )
            }
            return parsed
        }
        return decoder
    }

    private static func makeEncoder(style: Date.ISO8601FormatStyle) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(style.format(date))
        }
        return encoder
    }
}
