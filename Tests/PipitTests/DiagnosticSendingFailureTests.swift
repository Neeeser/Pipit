import Foundation
import PipitCore
import Testing

@testable import PipitServices

@Suite("Diagnostic sending failures")
struct DiagnosticSendingFailureTests {
    @Test("a report without its deletion secret never leaves the Mac")
    func missingSecretPreventsSending() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FakeReportTransport()
        let sender = DiagnosticReportSender(
            layout: DiagnosticLayout(root: root), transport: transport, secrets: InMemoryDeletionSecrets()
        )
        let report = try DiagnosticDeliveryFixtures.report()
        #expect(await sender.send(report) == .failed)
        #expect(transport.requestCount == 0)
        #expect(await sender.pending().isEmpty)
    }

    @Test("a receipt write failure keeps the report and secret for an idempotent retry")
    func receiptWriteFailureKeepsTheOutbox() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = DiagnosticLayout(root: root)
        let transport = FakeReportTransport()
        let secrets = InMemoryDeletionSecrets()
        let clock = ManualDeliveryClock()
        let sender = DiagnosticReportSender(
            layout: layout, transport: transport, secrets: secrets, now: { clock.now }, random: { 0 }
        )
        let identity = sender.prepareIdentity()
        let report = try DiagnosticDeliveryFixtures.report(
            reportID: identity.reportID, hash: identity.deletionSecretHash
        )
        try FileManager.default.createDirectory(at: layout.outbox, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        #expect(throws: StorageError.self) {
            try AtomicFile.write(Data(), to: layout.sentReceipts)
        }
        let first = await sender.send(report)
        #expect(first == .willRetry(at: clock.now.addingTimeInterval(30)))
        #expect(await sender.pending().map(\.reportID) == [report.reportID])
        #expect(secrets.secret(reportID: report.reportID) != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        clock.advance(by: 31)
        #expect(await sender.retryDue(includeAutomatic: false).count == 1)
        #expect(await sender.receipts().map(\.reportID) == [report.reportID])
        #expect(transport.submissions.count == 2)
        #expect(transport.submissions.first?.body == transport.submissions.last?.body)
    }

    @Test("turning sharing off during an upload deletes the report after the upload finishes")
    func disablingDuringUploadDeletesAfterCompletion() async throws {
        for result in [true, false] {
            let root = try TestPaths.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let transport = SuspendedReportTransport()
            let secrets = InMemoryDeletionSecrets()
            let sender = DiagnosticReportSender(
                layout: DiagnosticLayout(root: root), transport: transport, secrets: secrets
            )
            let identity = sender.prepareIdentity()
            let report = try DiagnosticDeliveryFixtures.report(
                kind: .automatic, reportID: identity.reportID, hash: identity.deletionSecretHash
            )
            let sending = Task { await sender.send(report, automatic: true) }
            await transport.answer.waitUntilRequested()
            await sender.discardAutomatic()
            await transport.answer.resume(
                result
                    ? .accepted(FakeReportTransport.receipt(report.reportID))
                    : .unavailable(status: 503, retryAfter: nil)
            )
            _ = await sending.value
            #expect(await sender.receipts().isEmpty)
            #expect(await sender.pending().isEmpty)
            #expect(secrets.stored.isEmpty)
            #expect(await transport.deletions == [report.reportID])
        }
    }

    @Test("turning sharing off while a report is built prevents its upload and discards its identity")
    func disablingDuringBuildPreventsUpload() async throws {
        for (kind, reenable) in [DiagnosticReport.Kind.crash, .automatic].flatMap({ kind in
            [false, true].map { (kind, $0) }
        }) {
            let root = try TestPaths.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let transport = FakeReportTransport()
            let secrets = InMemoryDeletionSecrets()
            let clock = ManualDeliveryClock()
            let conditions = SharingConditions(enabled: true)
            let sender = DiagnosticReportSender(
                layout: DiagnosticLayout(root: root), transport: transport, secrets: secrets
            )
            let identity = sender.prepareIdentity()
            let report = try DiagnosticDeliveryFixtures.report(
                kind: kind, reportID: identity.reportID, hash: identity.deletionSecretHash
            )
            let build = SuspendedDiagnosticValue<DiagnosticReport?>()
            let scheduler = DiagnosticSharingScheduler(
                sender: sender, layout: DiagnosticLayout(root: root), isEnabled: { conditions.isEnabled },
                isBusy: { false }, network: { .unmetered }, now: { clock.now }, random: { 0 },
                buildReport: { _, _ in await build.value() }
            )
            await scheduler.enable()
            if kind == .crash {
                await scheduler.noteCrash(incident: UUID().uuidString.lowercased(), since: clock.now)
            } else {
                clock.advance(by: 86_401)
            }
            let ticking = Task { await scheduler.tick() }
            await build.waitUntilRequested()
            conditions.isEnabled = false
            await scheduler.disable()
            if reenable {
                conditions.isEnabled = true
                await scheduler.enable()
            }
            await build.resume(report)
            _ = await ticking.value
            #expect(transport.requestCount == 0)
            #expect(secrets.stored.isEmpty)
            #expect(await sender.pending().isEmpty)
        }
    }
}

/// A boundary operation a test releases after another actor has changed state.
actor SuspendedDiagnosticValue<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func value() async -> Value {
        await withCheckedContinuation {
            continuation = $0
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilRequested() async {
        if continuation != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func resume(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private actor SuspendedReportTransport: DiagnosticReportTransport {
    let answer = SuspendedDiagnosticValue<DiagnosticSubmitResult>()
    private(set) var deletions: [String] = []

    func submit(body: Data, reportID: String) async -> DiagnosticSubmitResult { await answer.value() }
    func status(id: String, secret: String) async -> DiagnosticLookupResult { .notFound }
    func delete(id: String, secret: String) async -> DiagnosticDeleteResult {
        deletions.append(id)
        return .deleted
    }
}
