import Foundation

/// What to do with a queued report after an attempt, and when to try again
/// (`docs/DIAGNOSTICS.md`, Report service).
public enum DiagnosticSendPolicy {
    public enum Disposition: Sendable, Equatable {
        /// Stored. Move it to the receipts.
        case confirmed(DiagnosticServiceReceipt)
        /// The service will never take this body. Drop it.
        case dropped
        /// Worth another attempt with the same ID and body, no sooner than
        /// `retryAfter` when the service named a wait.
        case retry(retryAfter: TimeInterval?)
    }

    /// The first retry waits about this long.
    public static let initialDelay: TimeInterval = 60
    /// No wait is longer than this, a `Retry-After` included.
    public static let maximumDelay: TimeInterval = 6 * 60 * 60

    public static func disposition(for result: DiagnosticSubmitResult) -> Disposition {
        switch result {
        case .accepted(let receipt), .replayed(let receipt):
            .confirmed(receipt)
        case .conflict, .invalid, .tooLarge, .unsupportedMediaType, .unexpected:
            .dropped
        case .rateLimited(let retryAfter), .unavailable(_, let retryAfter):
            .retry(retryAfter: retryAfter)
        case .unreadableReceipt, .network:
            .retry(retryAfter: nil)
        }
    }

    /// `report.sent`'s `outcome`.
    public static func eventOutcome(for result: DiagnosticSubmitResult) -> DiagnosticEvent.ReportOutcome {
        switch result {
        case .accepted: .accepted
        case .replayed: .replayed
        case .conflict, .invalid, .tooLarge, .unsupportedMediaType, .unexpected: .rejected
        case .rateLimited, .unavailable, .unreadableReceipt, .network: .failed
        }
    }

    /// The wait after `attempts` failed attempts: doubling from
    /// `initialDelay`, capped at `maximumDelay`, with the upper half
    /// jittered by `random` in `0..<1` so Macs that failed together do not
    /// retry together. Never shorter than the service's `Retry-After`.
    public static func retryDelay(afterAttempts attempts: Int, retryAfter: TimeInterval?, random: Double)
        -> TimeInterval
    {
        let exponent = Double(min(max(attempts - 1, 0), 30))
        let ceiling = min(maximumDelay, initialDelay * pow(2, exponent))
        let unit = min(max(random, 0), 1)
        let jittered = ceiling / 2 + ceiling / 2 * unit
        guard let retryAfter, retryAfter.isFinite else { return jittered }
        return max(jittered, min(retryAfter, maximumDelay))
    }
}
