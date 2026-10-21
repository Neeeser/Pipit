import CryptoKit
import Foundation
import PipitCore
import Security

/// Deletion secrets of sent reports, in the login keychain: service
/// `com.pipit.app.report-deletion`, account = the report ID, lowercase
/// (`docs/DIAGNOSTICS.md`, Report service).
///
/// A secret is 32 bytes from `SecRandomCopyBytes`, written as canonical
/// base64url. The report carries only its hash, base64url(SHA-256(UTF-8 of
/// the secret)), so the service can check a deletion without being able to
/// make one. A secret is never logged and never written to a file.
public struct KeychainDeletionSecrets: DiagnosticDeletionSecrets {
    public static let service = "com.pipit.app.report-deletion"

    public let service: String

    public init(service: String = KeychainDeletionSecrets.service) {
        self.service = service
    }

    public func generate() -> String {
        Self.generate()
    }

    public func hash(of secret: String) -> String {
        Self.hash(of: secret)
    }

    /// 32 random bytes, canonical base64url. `SystemRandomNumberGenerator`,
    /// which also reads the kernel's generator, stands in on the rare
    /// failure of `SecRandomCopyBytes`.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: DiagnosticDeletionCode.secretByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: 0...255, using: &generator) }
        }
        return DiagnosticBase64URL.encode(Data(bytes))
    }

    /// base64url(SHA-256(UTF-8 of `secret`)), 43 characters.
    public static func hash(of secret: String) -> String {
        DiagnosticBase64URL.encode(Data(SHA256.hash(data: Data(secret.utf8))))
    }

    @discardableResult
    public func store(_ secret: String, reportID: String) -> Bool {
        let base = query(reportID: reportID)
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(secret.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public func secret(reportID: String) -> String? {
        var lookup = query(reportID: reportID)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func remove(reportID: String) -> Bool {
        let status = SecItemDelete(query(reportID: reportID) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func query(reportID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reportID.lowercased(),
        ]
    }
}
