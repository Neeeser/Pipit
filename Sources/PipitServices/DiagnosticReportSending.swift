import Foundation
import PipitCore

/// What became of a report handed to a sender.
public enum DiagnosticSendOutcome: Sendable, Equatable {
    /// The report service has it.
    case sent(reportID: String)
    /// Kept in the outbox, to be sent when it can be.
    case queued(reportID: String)
    /// It was not sent and is not waiting to be.
    case failed
    /// Nothing in this build sends reports.
    case unavailable
}

/// Sends a diagnostic report to the report service (`docs/DIAGNOSTICS.md`,
/// Report service).
///
/// The report it is handed carries a provisional identity, made by
/// `DiagnosticReportIdentity.provisional()`. A sender makes the report ID
/// and the deletion secret it will keep before the first attempt, and writes
/// both into the report before encoding it; the two are a fixed length, so
/// the size the preview showed does not change.
public protocol DiagnosticReportSending: Sendable {
    func send(_ report: DiagnosticReport) async -> DiagnosticSendOutcome
}

/// The sender until one is wired in. Sends nothing.
public struct UnavailableDiagnosticReportSender: DiagnosticReportSending {
    public init() {}

    public func send(_ report: DiagnosticReport) async -> DiagnosticSendOutcome { .unavailable }
}

/// A report's ID and the hash of its deletion secret.
public struct DiagnosticReportIdentity: Sendable, Equatable {
    public var reportID: String
    /// base64url(SHA-256(deletion secret)), 43 characters.
    public var deletionSecretHash: String

    public init(reportID: String, deletionSecretHash: String) {
        self.reportID = reportID
        self.deletionSecretHash = deletionSecretHash
    }

    /// A random ID, and 32 random bytes in the hash's place, for a report
    /// that is previewed or exported. Nobody holds a secret that hashes to
    /// it, and it says nothing about the Mac a sent report would not.
    public static func provisional() -> DiagnosticReportIdentity {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return DiagnosticReportIdentity(
            reportID: UUID().uuidString.lowercased(), deletionSecretHash: base64URL(Data(bytes))
        )
    }

    /// Unpadded base64url, the form the contract gives the hash in.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
