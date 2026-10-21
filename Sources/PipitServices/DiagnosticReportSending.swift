import Foundation
import PipitCore

/// Sends a built report to the report service.
///
/// The report builder stamps a report with an identity from
/// `DiagnosticReportSender.prepareIdentity()` and hands it here.
/// `DiagnosticReportSender` is the implementation.
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
