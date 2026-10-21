import Foundation
import PipitCore

/// Sends a built report to the report service (`docs/DIAGNOSTICS.md`, Report
/// service).
///
/// `DiagnosticReportSender` is the implementation. The report it is handed
/// carries the identity the sender gave out for it, from
/// `DiagnosticReportSender.prepareIdentity()`, so the report previewed is
/// the report sent.
public protocol DiagnosticReportSending: Sendable {
    func send(_ report: DiagnosticReport) async -> DiagnosticSendOutcome
}

/// How sending a report went, for the window that sent it.
public enum DiagnosticSendOutcome: Sendable, Equatable {
    /// The service stored it. The receipt is in Sent reports.
    case sent(DiagnosticReceipt)
    /// Not confirmed yet. It stays queued and is tried again from this time,
    /// with the same ID and body, for up to 7 days.
    case willRetry(at: Date)
    /// The service will not take it, or the app found it would not. Not
    /// queued.
    case rejected(DiagnosticSendRejection)
    /// It could not be queued and the one attempt failed, or its queued body
    /// is gone.
    case failed
    /// Nothing in this build sends reports.
    case unavailable
}

public enum DiagnosticSendRejection: Sendable, Equatable {
    /// The report breaks the format: found by the app before sending, or a
    /// 400 from the service with its code for the rule.
    case invalidReport(error: String?)
    /// 409: the ID is stored with other contents.
    case conflict
    /// Over the compressed limit, here or at the service.
    case tooLarge
    case unsupportedMediaType
    case unexpectedStatus(Int)
}

/// How deleting a sent report went.
public enum DiagnosticDeletionOutcome: Sendable, Equatable {
    /// The service deleted it.
    case deleted
    /// The service has no such report: expired, deleted from the website, or
    /// the secret no longer matches. The receipt is removed either way.
    case alreadyGone
    /// The deletion secret is not in the Keychain, so this Mac cannot ask.
    case noSecret
    /// No answer, or an unexpected one. Nothing was removed.
    case failed
}

/// The sender until one is wired in, and in a runtime whose log writes
/// nowhere. Sends nothing.
public struct UnavailableDiagnosticReportSender: DiagnosticReportSending {
    public init() {}

    public func send(_ report: DiagnosticReport) async -> DiagnosticSendOutcome { .unavailable }
}

/// A report's ID and the hash of its deletion secret.
public struct DiagnosticReportIdentity: Sendable, Equatable {
    /// A lowercase UUID.
    public var reportID: String
    /// base64url(SHA-256(deletion secret)), 43 characters.
    public var deletionSecretHash: String

    public init(reportID: String, deletionSecretHash: String) {
        self.reportID = reportID
        self.deletionSecretHash = deletionSecretHash
    }

    /// A random ID, and 32 random bytes in the hash's place, for a report
    /// that is exported or previewed with no sender. Nobody holds a secret
    /// that hashes to it, and it says nothing about the Mac a sent report
    /// would not.
    public static func provisional() -> DiagnosticReportIdentity {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return DiagnosticReportIdentity(
            reportID: UUID().uuidString.lowercased(), deletionSecretHash: DiagnosticBase64URL.encode(Data(bytes))
        )
    }
}
