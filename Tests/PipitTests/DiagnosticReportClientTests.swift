import Foundation
import PipitCore
import Testing

@testable import PipitIntegrations
@testable import PipitServices

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The report service client against a stub server inside one session, so
/// nothing reaches the website (`docs/DIAGNOSTICS.md`, Report service).
@Suite("Diagnostic report client")
struct DiagnosticReportClientTests {
    static let reportID = "5b0c6a3e-8f1d-4c2a-9e7b-1d2f3a4b5c6d"
    static let secret = DiagnosticBase64URL.encode(Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) }))
    static let receiptJSON: [String: String] = [
        "reportID": reportID, "receivedAt": "2026-10-21T03:18:16Z", "expiresAt": "2027-01-19T03:18:16Z",
    ]
    static let receipt = DiagnosticServiceReceipt(
        reportID: reportID, receivedAt: DiagnosticsFixtures.utc("2026-10-21T03:18:16Z"),
        expiresAt: DiagnosticsFixtures.utc("2027-01-19T03:18:16Z")
    )

    /// Every line the client logs.
    final class LogLines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    private func client(_ server: StubServer, log: LogLines = LogLines()) -> DiagnosticReportClient {
        DiagnosticReportClient(
            configuration: .init(baseURL: server.baseURL(), version: "0.1.8"), session: server.session,
            log: { log.append($0) }, now: { DiagnosticsFixtures.utc("2026-10-21T09:00:00Z") }
        )
    }

    @Test("a report is posted to /api/reports with the contract's headers and the exact body")
    func aReportIsPostedWithTheContractsHeaders() async throws {
        let server = StubServer { _ in .json(Self.receiptJSON, status: 201) }
        let body = try DiagnosticCompression.gzip(Data(#"{"schemaVersion":1}"#.utf8))
        let result = await client(server).submit(body: body, reportID: Self.reportID)
        #expect(result == .accepted(Self.receipt))

        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.method == "POST")
        #expect(request.path == "/api/reports")
        #expect(request.header("Content-Type") == "application/vnd.pipit.report+json")
        #expect(request.header("Content-Encoding") == "gzip")
        #expect(request.header("Idempotency-Key") == Self.reportID)
        #expect(request.header("User-Agent") == "Pipit/0.1.8")
        #expect(request.header("Authorization") == nil)
        #expect(request.header("Cookie") == nil)
        #expect(request.body == body)
    }

    @Test("each answer of the service comes back as its own result")
    func eachAnswerComesBackAsItsOwnResult() async throws {
        let cases: [(StubReply, DiagnosticSubmitResult)] = [
            (.json(Self.receiptJSON, status: 201), .accepted(Self.receipt)),
            (.json(Self.receiptJSON, status: 200), .replayed(Self.receipt)),
            (.json(["error": "conflict"], status: 409), .conflict),
            (.json(["error": "too_many_events"], status: 400), .invalid(error: "too_many_events")),
            (.json(["error": "too_large"], status: 413), .tooLarge),
            (.json(["error": "unsupported_media_type"], status: 415), .unsupportedMediaType),
            (StubReply(status: 429, headers: ["Retry-After": "120"]), .rateLimited(retryAfter: 120)),
            (
                StubReply(status: 429, headers: ["Retry-After": "Wed, 21 Oct 2026 09:05:00 GMT"]),
                .rateLimited(retryAfter: 300)
            ),
            (.json(["error": "daily_cap"], status: 503), .unavailable(status: 503, retryAfter: nil)),
            (.json(["error": "internal"], status: 500), .unavailable(status: 500, retryAfter: nil)),
            (.json([:], status: 201), .unreadableReceipt(status: 201)),
            (.fails(.timedOut), .network(DiagnosticCode.error(domain: "NSURLErrorDomain", code: -1001))),
            (.down, .network(DiagnosticCode.error(domain: "NSURLErrorDomain", code: -1004))),
        ]
        for (reply, expected) in cases {
            let server = StubServer { _ in reply }
            let result = await client(server).submit(body: Data([1, 2, 3]), reportID: Self.reportID)
            #expect(result == expected, "\(expected)")
        }
    }

    @Test("a lookup and a deletion carry the secret as a bearer token, on the report's own path")
    func aLookupAndADeletionCarryTheSecret() async throws {
        let server = StubServer { request in
            switch (request.method, request.header("Authorization")) {
            case ("GET", "Bearer \(Self.secret)"): .json(Self.receiptJSON)
            case ("DELETE", "Bearer \(Self.secret)"): StubReply(status: 204)
            default: .json(["error": "not_found"], status: 404)
            }
        }
        let client = client(server)
        #expect(await client.status(id: Self.reportID.uppercased(), secret: Self.secret) == .found(Self.receipt))
        #expect(await client.status(id: Self.reportID, secret: "wrong-secret-value-1234") == .notFound)
        #expect(await client.delete(id: Self.reportID, secret: Self.secret) == .deleted)
        #expect(await client.delete(id: Self.reportID, secret: "wrong-secret-value-1234") == .notFound)
        #expect(server.requests.map(\.path).allSatisfy { $0 == "/api/reports/\(Self.reportID)" })
        #expect(server.requests.map(\.method) == ["GET", "GET", "DELETE", "DELETE"])
        #expect(server.requests.allSatisfy { $0.header("User-Agent") == "Pipit/0.1.8" && $0.body.isEmpty })

        let failing = StubServer { _ in .json(["error": "internal"], status: 500) }
        #expect(await self.client(failing).delete(id: Self.reportID, secret: Self.secret) == .failed(status: 500))
        let down = StubServer { _ in .down }
        #expect(await self.client(down).delete(id: Self.reportID, secret: Self.secret) == .failed(status: nil))
        // An ID that is not a UUID never becomes a path.
        #expect(await self.client(down).delete(id: "../cron", secret: Self.secret) == .notFound)
        #expect(down.requests.count == 1)
    }

    @Test("the log holds report IDs, sizes and statuses, never a secret or a body")
    func theLogHoldsNoSecretOrBody() async throws {
        let server = StubServer { request in
            request.method == "POST" ? .json(Self.receiptJSON, status: 201) : StubReply(status: 204)
        }
        let log = LogLines()
        let client = client(server, log: log)
        let marker = "CANARY-note-text"
        let body = Data(#"{"note":"\#(marker)"}"#.utf8)
        _ = await client.submit(body: body, reportID: Self.reportID)
        _ = await client.status(id: Self.reportID, secret: Self.secret)
        _ = await client.delete(id: Self.reportID, secret: Self.secret)
        #expect(log.all.count == 3)
        for line in log.all {
            #expect(line.contains(Self.reportID))
            #expect(!line.contains(Self.secret))
            #expect(!line.contains(marker))
        }
        #expect(log.all.first?.contains("\(body.count) bytes") == true)
    }

    @Test("the session keeps no cookies, cache or credentials, and waits 30 seconds")
    func theSessionKeepsNothing() {
        let configuration = DiagnosticReportClient.sessionConfiguration()
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.timeoutIntervalForRequest == 30)
        #expect(DiagnosticReportClient.Configuration(version: "0.1.8").timeout == 30)
    }

    @Test("the base URL is the website unless Info.plist names another http or https address")
    func theBaseURLIsTheWebsiteByDefault() {
        let standard = URL(string: "https://pipit-website.vercel.app")
        #expect(DiagnosticReportClient.Configuration.defaultBaseURL == standard)
        #expect(DiagnosticReportClient.Configuration.baseURL(from: nil) == standard)
        #expect(DiagnosticReportClient.Configuration.baseURL(from: "") == standard)
        #expect(DiagnosticReportClient.Configuration.baseURL(from: "file:///tmp/x") == standard)
        #expect(DiagnosticReportClient.Configuration.baseURL(from: "not a url") == standard)
        #expect(
            DiagnosticReportClient.Configuration.baseURL(from: "http://localhost:3000")
                == URL(string: "http://localhost:3000"))
        #expect(DiagnosticReportClient.Configuration(version: "0.1.0 dev").userAgent == "Pipit/invalid")
    }

    @Test("through the real client, a lost answer and a retry give one receipt and the same bytes twice")
    func throughTheRealClientALostAnswerAndARetryGiveOneReceipt() async throws {
        let attempts = LogLines()
        let server = StubServer { request in
            attempts.append(request.header("Idempotency-Key") ?? "")
            guard attempts.all.count > 1, let id = request.header("Idempotency-Key") else { return .down }
            var receipt = Self.receiptJSON
            receipt["reportID"] = id
            return .json(receipt, status: 200)
        }
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = ManualDeliveryClock()
        let sender = DiagnosticReportSender(
            layout: DiagnosticLayout(root: root), transport: client(server), secrets: InMemoryDeletionSecrets(),
            now: { clock.now }, random: { 0 }
        )
        let identity = sender.prepareIdentity()
        let report = try DiagnosticDeliveryFixtures.report(
            reportID: identity.reportID, hash: identity.deletionSecretHash
        )
        guard case .willRetry = await sender.send(report) else {
            Issue.record("the first attempt was not queued")
            return
        }
        clock.advance(by: 31)
        #expect(await sender.retryDue(includeAutomatic: false).count == 1)
        #expect(server.requests.count == 2)
        #expect(server.requests[0].body == server.requests[1].body)
        #expect(await sender.receipts().map(\.reportID) == [report.reportID])
        #expect(await sender.pending().isEmpty)
    }

    #if canImport(CryptoKit)
        @Test("a deletion secret is 32 random bytes in canonical base64url, and its hash matches the fixture's")
        func aDeletionSecretIsCanonicalAndItsHashMatchesTheFixture() throws {
            let fixture = try DiagnosticReport.decode(Data(contentsOf: DiagnosticsFixtures.report))
            #expect(
                KeychainDeletionSecrets.hash(of: "synthetic-deletion-secret-for-fixtures")
                    == "zJk90jTVjCvAIbe9mWlHJMzML8SbnpzjNUx1hwySPi0")
            #expect(
                fixture.deletionSecretHash == KeychainDeletionSecrets.hash(of: "synthetic-deletion-secret-for-fixtures")
            )
            let secrets = (0..<20).map { _ in KeychainDeletionSecrets.generate() }
            #expect(Set(secrets).count == secrets.count)
            for secret in secrets {
                #expect(secret.count == 43)
                #expect(DiagnosticDeletionCode.isSecret(secret))
                #expect(DiagnosticBase64URL.isCanonical(KeychainDeletionSecrets.hash(of: secret), byteCount: 32))
            }
            #expect(KeychainDeletionSecrets.service == "com.pipit.app.report-deletion")
        }
    #endif
}
