import Foundation
import PipitCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The report service on the website (`docs/DIAGNOSTICS.md`, Report
/// service): `POST /api/reports`, and `GET` and `DELETE` of
/// `/api/reports/<id>` with the deletion secret.
///
/// The session is ephemeral, with no cookies, no cache, and no credential
/// store, and every request carries only what the contract names plus a
/// `User-Agent` of `Pipit/<version>`. A log line holds the report ID, the
/// size, and the status. The body, the secret, a note, and a contact are
/// never logged.
public struct DiagnosticReportClient: DiagnosticReportTransport {
    public struct Configuration: Sendable, Equatable {
        // swiftlint:disable:next force_unwrapping
        public static let defaultBaseURL = URL(string: "https://pipit-website.vercel.app")!
        /// The Info.plist key that overrides the base URL, for a build
        /// pointed at a preview deployment or a local server.
        public static let baseURLKey = "PipitReportServiceURL"

        public var baseURL: URL
        /// How long a request may wait for the service.
        public var timeout: TimeInterval
        public var userAgent: String

        public init(baseURL: URL = Configuration.defaultBaseURL, timeout: TimeInterval = 30, version: String) {
            self.baseURL = baseURL
            self.timeout = timeout
            self.userAgent = "Pipit/\(DiagnosticToken.version(version).value)"
        }

        /// The base URL and version a bundle names. A key that is missing,
        /// empty, or not an http or https URL with a host leaves the default.
        public static func standard(bundle: Bundle = .main) -> Configuration {
            let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
            return Configuration(
                baseURL: baseURL(from: bundle.object(forInfoDictionaryKey: baseURLKey) as? String),
                version: version ?? "unknown"
            )
        }

        static func baseURL(from value: String?) -> URL {
            guard let value = value?.trimmingCharacters(in: .whitespaces), let url = URL(string: value),
                let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil
            else { return defaultBaseURL }
            return url
        }
    }

    public static let contentType = "application/vnd.pipit.report+json"

    private let configuration: Configuration
    private let session: URLSession
    private let log: @Sendable (String) -> Void
    private let now: @Sendable () -> Date

    /// `session` defaults to one built from `sessionConfiguration`. `log`
    /// receives each line this client writes, which a test reads to show
    /// that no secret reaches it.
    public init(
        configuration: Configuration,
        session: URLSession? = nil,
        log: @escaping @Sendable (String) -> Void = DiagnosticReportClient.systemLog,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.session = session ?? URLSession(configuration: Self.sessionConfiguration(timeout: configuration.timeout))
        self.log = log
        self.now = now
    }

    /// Ephemeral, with nothing kept between requests: no cookies, no cache,
    /// no stored credentials.
    public static func sessionConfiguration(timeout: TimeInterval = 30) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        // A full 1 MiB body on a slow link takes longer than the wait for an
        // answer, so the whole transfer gets twice that.
        configuration.timeoutIntervalForResource = timeout * 2
        return configuration
    }

    // MARK: - requests

    public func submit(body: Data, reportID: String) async -> DiagnosticSubmitResult {
        guard UUID(uuidString: reportID) != nil else { return .unexpected(status: 0) }
        var request = makeRequest(path: "api/reports", method: "POST")
        request.setValue(Self.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        request.setValue(reportID, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = body
        let result: DiagnosticSubmitResult
        switch await perform(request) {
        case .success(let (status, data, retryAfter)):
            result = .from(status: status, body: data, retryAfter: retryAfter, reportID: reportID, now: now())
        case .failure(let code):
            result = .network(code)
        }
        log("report \(reportID.lowercased()) submit: \(body.count) bytes, \(Self.describe(result.status))")
        return result
    }

    public func status(id: String, secret: String) async -> DiagnosticLookupResult {
        guard UUID(uuidString: id) != nil else { return .notFound }
        var request = makeRequest(path: "api/reports/\(id.lowercased())", method: "GET")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let result: DiagnosticLookupResult
        let status: Int?
        switch await perform(request) {
        case .success(let (code, data, _)):
            status = code
            result = .from(status: code, body: data, reportID: id)
        case .failure:
            status = nil
            result = .failed(status: nil)
        }
        log("report \(id.lowercased()) lookup: \(Self.describe(status))")
        return result
    }

    public func delete(id: String, secret: String) async -> DiagnosticDeleteResult {
        guard UUID(uuidString: id) != nil else { return .notFound }
        var request = makeRequest(path: "api/reports/\(id.lowercased())", method: "DELETE")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let result: DiagnosticDeleteResult
        let status: Int?
        switch await perform(request) {
        case .success(let (code, _, _)):
            status = code
            result = .from(status: code)
        case .failure:
            status = nil
            result = .failed(status: nil)
        }
        log("report \(id.lowercased()) delete: \(Self.describe(status))")
        return result
    }

    /// Where log lines go outside a test. Each holds only a report ID, a
    /// size, and a status.
    public static func systemLog(_ line: String) {
        Log.integrations.info("\(line, privacy: .public)")
    }

    // MARK: - transport

    private func makeRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = configuration.timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private enum Answer {
        case success((status: Int, body: Data, retryAfter: String?))
        case failure(DiagnosticCode)
    }

    private func perform(_ request: URLRequest) async -> Answer {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(DiagnosticCode("report", "no_http_response"))
            }
            return .success((http.statusCode, data, http.value(forHTTPHeaderField: "Retry-After")))
        } catch {
            return .failure(DiagnosticCode(describing: error))
        }
    }

    private static func describe(_ status: Int?) -> String {
        status.map { "status \($0)" } ?? "no answer"
    }
}
