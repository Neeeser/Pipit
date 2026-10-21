import Foundation

/// A string that may stand in a diagnostic event, checked against the pattern
/// for what it is.
///
/// Every string in an event is either an enum's raw value, which Pipit wrote,
/// or one of these. Anything that came from outside Pipit (an add-on's own
/// version, the hardware model the kernel reports) is checked, and a value
/// that does not match reads `invalid`. The patterns admit no spaces, slashes,
/// `@` or quotes, so a title, a name, a path or an address cannot pass one.
public struct DiagnosticToken: Hashable, Sendable, CustomStringConvertible {
    public let value: String

    public static let invalid = DiagnosticToken(unchecked: "invalid")
    /// What a value reads as when there was none to report.
    public static let unknown = DiagnosticToken(unchecked: "unknown")

    private init(unchecked value: String) { self.value = value }

    public var description: String { value }

    /// `^[0-9A-Za-z.+-]{1,32}$`. Nil reads `unknown`.
    public static func version(_ raw: String?) -> DiagnosticToken {
        guard let raw else { return .unknown }
        return matches(raw, maximum: 32, extra: [".", "+", "-"]) ? DiagnosticToken(unchecked: raw) : .invalid
    }

    /// A commit is 40 lowercase hex digits, or `unknown` for a build that was
    /// not stamped. Longer than a version may be, so it has its own pattern.
    public static func commit(_ raw: String?) -> DiagnosticToken {
        guard let raw, raw != "unknown" else { return .unknown }
        let isHex = raw.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
        return isHex && (7...40).contains(raw.count) ? DiagnosticToken(unchecked: raw) : .invalid
    }

    /// A Mac model identifier such as `Mac15,3`. The comma is why it is not a
    /// version.
    public static func hardware(_ raw: String?) -> DiagnosticToken {
        guard let raw else { return .unknown }
        return matches(raw, maximum: 32, extra: [","]) ? DiagnosticToken(unchecked: raw) : .invalid
    }

    /// A short `snake_case` word Pipit chose, such as a warning's key.
    public static func word(_ raw: String) -> DiagnosticToken {
        let isWord =
            !raw.isEmpty && raw.count <= 48
            && raw.unicodeScalars.allSatisfy { scalar in
                ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_"
            }
        return isWord ? DiagnosticToken(unchecked: raw) : .invalid
    }

    private static func matches(_ raw: String, maximum: Int, extra: Set<Unicode.Scalar>) -> Bool {
        guard !raw.isEmpty, raw.count <= maximum else { return false }
        return raw.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                || extra.contains(scalar)
        }
    }
}
