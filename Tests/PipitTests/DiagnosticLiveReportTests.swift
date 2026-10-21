import Foundation
import PipitCore
import PipitIntegrations
import PipitServices
import Testing

@Suite(
    "Live diagnostic reports", .enabled(if: ProcessInfo.processInfo.environment["PIPIT_LIVE_DIAGNOSTICS_URL"] != nil))
struct DiagnosticLiveReportTests {
    @Test("a logged failure reaches the website, replays, and is deleted with its Keychain secret")
    func logUploadReplayAndDeletion() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["PIPIT_LIVE_DIAGNOSTICS_URL"])
        let baseURL = try #require(URL(string: address))
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = DiagnosticLayout(root: root)
        let log = DiagnosticLog(layout: layout, freeSpace: { _ in .max })
        log.record(
            .processingStageFailed(
                stage: .transcribing, attempt: 1, code: ProcessingError.rateLimited(retryAfter: nil).diagnosticCode,
                retryable: true)
        )
        #expect(log.flush())
        let events = layout.storedEvents()
        #expect(events.count == 1)
        let client = DiagnosticReportClient(configuration: .init(baseURL: baseURL, version: "0.1.8"))
        let secrets = KeychainDeletionSecrets(service: "com.pipit.app.report-deletion.tests.\(UUID().uuidString)")
        let sender = DiagnosticReportSender(layout: layout, transport: client, secrets: secrets, diagnostics: log)
        let identity = try #require(sender.prepareReportIdentity())
        defer { secrets.remove(reportID: identity.reportID) }
        let bundle = try DiagnosticBundleBuilder.build(
            DiagnosticBundleTests.contents(events: events, crashes: []),
            request: DiagnosticBundleRequest(
                reportID: identity.reportID, kind: .user, createdAt: Date(),
                deletionSecretHash: identity.deletionSecretHash, note: "Synthetic end-to-end diagnostic check"
            )
        )
        let result = await sender.send(bundle.report)
        guard case .sent(let receipt) = result else {
            Issue.record("website did not accept the report: \(result)")
            return
        }
        let secret = try #require(secrets.secret(reportID: identity.reportID))
        let expected = DiagnosticServiceReceipt(
            reportID: identity.reportID, receivedAt: receipt.receivedAt, expiresAt: receipt.expiresAt
        )
        #expect(await client.submit(body: bundle.gzipped, reportID: identity.reportID) == .replayed(expected))
        #expect(await client.status(id: identity.reportID, secret: secret) == .found(expected))
        #expect(await client.status(id: identity.reportID, secret: KeychainDeletionSecrets.generate()) == .notFound)
        #expect(await sender.deleteFromServer(reportID: identity.reportID) == .deleted)
        #expect(await client.status(id: identity.reportID, secret: secret) == .notFound)
        #expect(await sender.receipts().isEmpty)
        #expect(secrets.secret(reportID: identity.reportID) == nil)
        print(
            "Live diagnostics: logged failure, uploaded \(bundle.gzipped.count) bytes, replayed, looked up, deleted \(receipt.reportID)"
        )
    }
}
