import Foundation

/// What the report service answers for a stored report: `{reportID,
/// receivedAt, expiresAt}` (`docs/DIAGNOSTICS.md`, Report service).
public struct DiagnosticServiceReceipt: Codable, Sendable, Equatable {
    public var reportID: String
    public var receivedAt: Date
    public var expiresAt: Date

    public init(reportID: String, receivedAt: Date, expiresAt: Date) {
        self.reportID = reportID
        self.receivedAt = receivedAt
        self.expiresAt = expiresAt
    }

    /// Nil for a body that is not a receipt, or one for another report.
    static func decode(_ data: Data, reportID: String) -> DiagnosticServiceReceipt? {
        guard let receipt = try? DiagnosticCoding.makeDecoder().decode(Self.self, from: data),
            receipt.reportID.lowercased() == reportID.lowercased()
        else { return nil }
        return receipt
    }
}

/// How `POST /api/reports` went, one case per answer the service gives.
public enum DiagnosticSubmitResult: Sendable, Equatable {
    /// 201: stored now.
    case accepted(DiagnosticServiceReceipt)
    /// 200: stored before, by an earlier attempt with the same ID and body.
    case replayed(DiagnosticServiceReceipt)
    /// 409: the ID is stored with different contents.
    case conflict
    /// 400. `error` is the service's code for the broken rule, kept only when
    /// it passes the token rule.
    case invalid(error: String?)
    /// 413.
    case tooLarge
    /// 415.
    case unsupportedMediaType
    /// 429, from the rate limit in front of the service.
    case rateLimited(retryAfter: TimeInterval?)
    /// 503 (the daily cap or full storage) and every other 5xx.
    case unavailable(status: Int, retryAfter: TimeInterval?)
    /// A 200 or 201 whose body is not this report's receipt. The report may be
    /// stored, and a retry is answered with the receipt as a replay.
    case unreadableReceipt(status: Int)
    /// Any other status.
    case unexpected(status: Int)
    /// No answer: offline, a timeout, a refused connection, a TLS failure.
    case network(DiagnosticCode)

    /// The HTTP status, when there was an answer.
    public var status: Int? {
        switch self {
        case .accepted: 201
        case .replayed: 200
        case .conflict: 409
        case .invalid: 400
        case .tooLarge: 413
        case .unsupportedMediaType: 415
        case .rateLimited: 429
        case .unavailable(let status, _), .unreadableReceipt(let status), .unexpected(let status): status
        case .network: nil
        }
    }

    /// The result an answer stands for. `retryAfter` is the `Retry-After`
    /// header, read against `now` when it is a date.
    public static func from(
        status: Int, body: Data, retryAfter: String?, reportID: String, now: Date
    ) -> DiagnosticSubmitResult {
        switch status {
        case 200, 201:
            guard let receipt = DiagnosticServiceReceipt.decode(body, reportID: reportID) else {
                return .unreadableReceipt(status: status)
            }
            return status == 201 ? .accepted(receipt) : .replayed(receipt)
        case 400:
            return .invalid(error: errorCode(in: body))
        case 409:
            return .conflict
        case 413:
            return .tooLarge
        case 415:
            return .unsupportedMediaType
        case 429:
            return .rateLimited(retryAfter: DiagnosticRetryAfter.seconds(retryAfter, now: now))
        case 500..<600:
            return .unavailable(status: status, retryAfter: DiagnosticRetryAfter.seconds(retryAfter, now: now))
        default:
            return .unexpected(status: status)
        }
    }

    /// The `error` of a `{error}` body, when it passes the token rule. The
    /// service never quotes the input, and this keeps it that way here.
    static func errorCode(in body: Data) -> String? {
        guard let object = JSONValue.parse(body)?.objectValue, case .string(let code)? = object["error"],
            !code.isEmpty, DiagnosticTokenRule.accepts(code)
        else { return nil }
        return code
    }
}

/// How `GET /api/reports/<id>` went.
public enum DiagnosticLookupResult: Sendable, Equatable {
    case found(DiagnosticServiceReceipt)
    /// 404: no such report, or the secret does not match. The service does
    /// not say which.
    case notFound
    case failed(status: Int?)

    public static func from(status: Int, body: Data, reportID: String) -> DiagnosticLookupResult {
        switch status {
        case 200:
            guard let receipt = DiagnosticServiceReceipt.decode(body, reportID: reportID) else {
                return .failed(status: status)
            }
            return .found(receipt)
        case 404:
            return .notFound
        default:
            return .failed(status: status)
        }
    }
}

/// How `DELETE /api/reports/<id>` went.
public enum DiagnosticDeleteResult: Sendable, Equatable {
    /// 204.
    case deleted
    /// 404: already gone, expired, or the secret does not match.
    case notFound
    case failed(status: Int?)

    public static func from(status: Int) -> DiagnosticDeleteResult {
        switch status {
        case 204: .deleted
        case 404: .notFound
        default: .failed(status: status)
        }
    }

    /// Whether the report is no longer on the server as far as this Mac can
    /// tell, so the receipt and the secret can go.
    public var isGone: Bool {
        switch self {
        case .deleted, .notFound: true
        case .failed: false
        }
    }
}

/// `Retry-After`: a number of seconds, or an HTTP date.
public enum DiagnosticRetryAfter {
    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
    private static let lock = NSLock()

    /// Seconds to wait from `now`, never negative, or nil when the header is
    /// absent or unreadable.
    public static func seconds(_ header: String?, now: Date) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = Int(header) { return TimeInterval(max(0, seconds)) }
        let date = lock.withLock { httpDate.date(from: header) }
        guard let date else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

/// The report service as the app uses it. `DiagnosticReportClient` in
/// PipitIntegrations is the real one; a test stands in its own.
public protocol DiagnosticReportTransport: Sendable {
    /// Sends a gzip-compressed report body. `reportID` is the
    /// `Idempotency-Key`.
    func submit(body: Data, reportID: String) async -> DiagnosticSubmitResult
    func status(id: String, secret: String) async -> DiagnosticLookupResult
    func delete(id: String, secret: String) async -> DiagnosticDeleteResult
}

/// Deletion secrets: made, hashed, and kept in the Keychain under service
/// `com.pipit.app.report-deletion`, account = report ID.
/// `KeychainDeletionSecrets` in PipitIntegrations is the real one.
public protocol DiagnosticDeletionSecrets: Sendable {
    /// 32 random bytes, canonical base64url.
    func generate() -> String
    /// base64url(SHA-256(UTF-8 of `secret`)), 43 characters.
    func hash(of secret: String) -> String
    @discardableResult func store(_ secret: String, reportID: String) -> Bool
    func secret(reportID: String) -> String?
    @discardableResult func remove(reportID: String) -> Bool
}
