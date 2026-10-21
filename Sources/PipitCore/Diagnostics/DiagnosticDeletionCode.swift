import Foundation

/// base64url (RFC 4648 §5) without padding, the form of a deletion secret and
/// of `deletionSecretHash`.
public enum DiagnosticBase64URL {
    public static func encode(_ data: Data) -> String {
        var text = data.base64EncodedString()
        text = text.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        while text.hasSuffix("=") { text.removeLast() }
        return text
    }

    /// The bytes `text` stands for, or nil when it is not unpadded base64url.
    public static func decode(_ text: String) -> Data? {
        guard
            text.unicodeScalars.allSatisfy({ scalar in
                ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
                    || scalar == "-" || scalar == "_"
            })
        else { return nil }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        guard remainder != 1 else { return nil }
        if remainder > 0 { standard += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: standard)
    }

    /// Whether `text` is the one encoding of exactly `byteCount` bytes: no
    /// padding, and the unused bits of the last character zero. The service
    /// checks `deletionSecretHash` the same way.
    public static func isCanonical(_ text: String, byteCount: Int) -> Bool {
        guard let bytes = decode(text), bytes.count == byteCount else { return false }
        return encode(bytes) == text
    }
}

/// A deletion code, `<reportID>.<deletion secret>`, as Settings shows it and
/// the website's `/reports/delete` takes it (`docs/DIAGNOSTICS.md`, Report
/// service).
public enum DiagnosticDeletionCode {
    /// A deletion secret is this many random bytes.
    public static let secretByteCount = 32

    public static func make(reportID: String, secret: String) -> String {
        "\(reportID.lowercased()).\(secret)"
    }

    /// The report ID and secret in a code, or nil for text that is not one.
    public static func parse(_ code: String) -> (reportID: String, secret: String)? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dot = trimmed.firstIndex(of: ".") else { return nil }
        let reportID = String(trimmed[..<dot])
        let secret = String(trimmed[trimmed.index(after: dot)...])
        guard UUID(uuidString: reportID) != nil, isSecret(secret) else { return nil }
        return (reportID.lowercased(), secret)
    }

    /// Whether `text` has a secret's form: 32 bytes, canonical base64url.
    public static func isSecret(_ text: String) -> Bool {
        DiagnosticBase64URL.isCanonical(text, byteCount: secretByteCount)
    }
}
