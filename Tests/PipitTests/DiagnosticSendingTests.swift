import Foundation
import PipitCore
import Testing

@testable import PipitServices

/// Sending, retrying and deleting reports, and automatic sharing, against a
/// scripted service (`docs/DIAGNOSTICS.md`, Report service and Automatic
/// sharing). No request leaves the process.
@Suite("Diagnostic sending")
struct DiagnosticSendingTests {
    private struct Rig {
        let root: URL
        let layout: DiagnosticLayout
        let transport: FakeReportTransport
        let secrets = InMemoryDeletionSecrets()
        let clock = ManualDeliveryClock()
        let sender: DiagnosticReportSender

        init(_ script: [DiagnosticSubmitResult] = []) throws {
            root = try TestPaths.makeTemporaryDirectory()
            layout = DiagnosticLayout(root: root)
            transport = FakeReportTransport(script)
            sender = DiagnosticReportSender(
                layout: layout, transport: transport, secrets: secrets,
                now: { [clock] in clock.now }, random: { [clock] in clock.random }
            )
        }

        /// A report stamped the way the builder stamps one.
        func report(_ kind: DiagnosticReport.Kind = .user) throws -> DiagnosticReport {
            let identity = sender.prepareIdentity()
            return try DiagnosticDeliveryFixtures.report(
                kind: kind, reportID: identity.reportID, hash: identity.deletionSecretHash, createdAt: clock.now
            )
        }

        func scheduler(
            _ conditions: SharingConditions,
            build: @escaping DiagnosticSharingScheduler.BuildReport
        ) -> DiagnosticSharingScheduler {
            DiagnosticSharingScheduler(
                sender: sender, layout: layout,
                isEnabled: { conditions.isEnabled }, isBusy: { conditions.isBusy },
                network: { conditions.network }, now: { [clock] in clock.now },
                random: { [clock] in clock.random }, buildReport: build
            )
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// Builds stamped reports and counts what it was asked for.
    private final class Builder: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [(DiagnosticReport.Kind, Date?)] = []
        let make: @Sendable (DiagnosticReport.Kind) throws -> DiagnosticReport

        init(_ make: @escaping @Sendable (DiagnosticReport.Kind) throws -> DiagnosticReport) {
            self.make = make
        }

        var requests: [(DiagnosticReport.Kind, Date?)] { lock.withLock { asked } }

        func build(_ kind: DiagnosticReport.Kind, _ since: Date?) -> DiagnosticReport? {
            lock.withLock { asked.append((kind, since)) }
            return try? make(kind)
        }
    }

    private func builder(for rig: Rig) -> Builder {
        Builder { [rig] kind in try rig.report(kind) }
    }

    // MARK: - identity

    @Test("an identity stores a canonical secret under the lowercase report ID and returns its hash")
    func anIdentityStoresItsSecret() throws {
        let rig = try Rig()
        defer { rig.remove() }
        let identity = rig.sender.prepareIdentity()
        let secret = try #require(rig.secrets.secret(reportID: identity.reportID.uuidString))
        #expect(rig.secrets.stored.keys.first == identity.reportID.uuidString.lowercased())
        #expect(DiagnosticDeletionCode.isSecret(secret))
        #expect(identity.deletionSecretHash == rig.secrets.hash(of: secret))
        rig.sender.discardIdentity(identity.reportID)
        #expect(rig.secrets.stored.isEmpty)
    }

    // MARK: - sending

    @Test("a stored report becomes a receipt, leaves the outbox, and is recorded")
    func aStoredReportBecomesAReceipt() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let logs = DiagnosticLog(layout: rig.layout, freeSpace: { _ in .max })
        let sender = DiagnosticReportSender(
            layout: rig.layout, transport: rig.transport, secrets: rig.secrets, diagnostics: logs,
            now: { [clock = rig.clock] in clock.now }
        )
        let report = try rig.report()
        let outcome = await sender.send(report)
        guard case .sent(let receipt) = outcome else {
            Issue.record("not sent: \(outcome)")
            return
        }
        #expect(receipt.reportID == report.reportID)
        #expect(receipt.kind == .user)
        #expect(receipt.expiresAt == DiagnosticDeliveryFixtures.received.addingTimeInterval(90 * 86_400))
        #expect(await sender.receipts() == [receipt])
        #expect(await sender.pending().isEmpty)
        #expect(rig.secrets.secret(reportID: report.reportID) != nil)

        let submission = try #require(rig.transport.submissions.first)
        #expect(submission.reportID == report.reportID)
        #expect(receipt.bytes == submission.body.count)
        #expect(try DiagnosticDeliveryPolicyTests.gunzip(submission.body) == report.encoded())

        #expect(logs.flush())
        let text = try Self.eventText(under: rig.root)
        #expect(text.contains(#""kind":"report.sent""#))
        #expect(text.contains(#""outcome":"accepted""#))
        #expect(text.contains(#""status":201"#))
    }

    @Test("a lost answer and a retry give one receipt, and both attempts send the same bytes")
    func aLostAnswerAndARetryGiveOneReceipt() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let report = try rig.report()
        let lost = DiagnosticSubmitResult.network(.error(domain: "NSURLErrorDomain", code: -1005))
        rig.transport.answer(next: lost)
        rig.transport.answer(next: .replayed(FakeReportTransport.receipt(report.reportID)))

        let first = await rig.sender.send(report)
        guard case .willRetry(let at) = first else {
            Issue.record("not queued: \(first)")
            return
        }
        #expect(at == rig.clock.now.addingTimeInterval(45))
        let queued = try #require(await rig.sender.pending().first)
        #expect(queued.attempts == 1)
        let onDisk = try #require(DiagnosticOutbox(layout: rig.layout).body(for: report.reportID))
        #expect(onDisk == rig.transport.submissions[0].body)

        // Not due yet.
        #expect(await rig.sender.retryDue(includeAutomatic: false).isEmpty)
        #expect(rig.transport.submissions.count == 1)

        rig.clock.advance(by: 46)
        let confirmed = await rig.sender.retryDue(includeAutomatic: false)
        #expect(confirmed.map(\.reportID) == [report.reportID])
        #expect(rig.transport.submissions.count == 2)
        #expect(rig.transport.submissions[0].body == rig.transport.submissions[1].body)
        #expect(rig.transport.submissions.allSatisfy { $0.reportID == report.reportID })
        #expect(await rig.sender.receipts().map(\.reportID) == [report.reportID])
        #expect(await rig.sender.pending().isEmpty)

        // Sending the same report again sends nothing new.
        #expect(await rig.sender.retryDue(includeAutomatic: false).isEmpty)
        #expect(rig.transport.submissions.count == 2)
    }

    @Test("sending a queued report again reuses its body rather than encoding it anew")
    func sendingAQueuedReportAgainReusesItsBody() async throws {
        let rig = try Rig([.unavailable(status: 503, retryAfter: nil)])
        defer { rig.remove() }
        var report = try rig.report()
        _ = await rig.sender.send(report)
        // The same ID with other contents would be a conflict at the service.
        report.summary.storage.meetings += 1
        rig.transport.answer(next: .replayed(FakeReportTransport.receipt(report.reportID)))
        _ = await rig.sender.send(report)
        let bodies = rig.transport.submissions.map(\.body)
        #expect(bodies.count == 2)
        #expect(bodies[0] == bodies[1])
    }

    @Test("a refused report is dropped with its secret, and a limit keeps it queued")
    func aRefusedReportIsDropped() async throws {
        for (answer, rejection) in [
            (DiagnosticSubmitResult.conflict, DiagnosticSendRejection.conflict),
            (.invalid(error: "token_rule"), .invalidReport(error: "token_rule")),
            (.tooLarge, .tooLarge),
            (.unsupportedMediaType, .unsupportedMediaType),
        ] {
            let rig = try Rig([answer])
            defer { rig.remove() }
            let report = try rig.report()
            #expect(await rig.sender.send(report) == .rejected(rejection))
            #expect(await rig.sender.pending().isEmpty)
            #expect(await rig.sender.receipts().isEmpty)
            #expect(rig.secrets.stored.isEmpty)
        }

        let rig = try Rig([.rateLimited(retryAfter: 900)])
        defer { rig.remove() }
        let report = try rig.report()
        #expect(await rig.sender.send(report) == .willRetry(at: rig.clock.now.addingTimeInterval(900)))
        #expect(await rig.sender.pending().map(\.reportID) == [report.reportID])
        #expect(rig.secrets.secret(reportID: report.reportID) != nil)
    }

    @Test("a report that breaks the format or the size limit is never sent")
    func aBrokenReportIsNeverSent() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        var report = try rig.report(.automatic)
        report.note = "free text on an automatic report"
        #expect(await rig.sender.send(report) == .rejected(.invalidReport(error: nil)))
        #expect(rig.transport.requestCount == 0)
        #expect(await rig.sender.pending().isEmpty)
    }

    @Test("a report unconfirmed after 7 days is dropped")
    func aReportUnconfirmedAfterSevenDaysIsDropped() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        rig.transport.fallback = .network(.error(domain: "NSURLErrorDomain", code: -1009))
        _ = await rig.sender.send(try rig.report())
        for _ in 0..<40 {
            rig.clock.advance(by: DiagnosticSendPolicy.maximumDelay)
            _ = await rig.sender.retryDue(includeAutomatic: false)
        }
        #expect(await rig.sender.pending().isEmpty)
        #expect(rig.secrets.stored.isEmpty)
        // 7 days of waits that reach 6 hours, then the drop.
        #expect(rig.transport.submissions.count < 40)
    }

    @Test("deleting a sent report removes the receipt and the secret on 204 and on 404, and nothing on a failure")
    func deletingASentReport() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let first = try rig.report()
        let second = try rig.report()
        _ = await rig.sender.send(first)
        _ = await rig.sender.send(second)
        let code = try #require(await rig.sender.deletionCode(reportID: first.reportID))
        let parsed = try #require(DiagnosticDeletionCode.parse(code))
        #expect(parsed.reportID == first.reportID)

        rig.transport.deleteAnswer = .failed(status: nil)
        #expect(await rig.sender.deleteFromServer(reportID: first.reportID) == .failed)
        #expect(await rig.sender.receipts().count == 2)

        rig.transport.deleteAnswer = .deleted
        #expect(await rig.sender.deleteFromServer(reportID: first.reportID) == .deleted)
        #expect(rig.transport.deletions.last?.secret == parsed.secret)
        rig.transport.deleteAnswer = .notFound
        #expect(await rig.sender.deleteFromServer(reportID: second.reportID) == .alreadyGone)
        #expect(await rig.sender.receipts().isEmpty)
        #expect(rig.secrets.stored.isEmpty)
        #expect(await rig.sender.deleteFromServer(reportID: first.reportID) == .noSecret)
    }

    @Test("forgetting sent reports removes every receipt and secret, and clearing the outbox its secrets")
    func forgettingSentReports() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        _ = await rig.sender.send(try rig.report())
        rig.transport.answer(next: .unavailable(status: 503, retryAfter: nil))
        _ = await rig.sender.send(try rig.report())
        #expect(rig.secrets.stored.count == 2)

        await rig.sender.discardOutbox()
        #expect(await rig.sender.pending().isEmpty)
        #expect(rig.secrets.stored.count == 1)
        await rig.sender.forgetSentReports()
        #expect(await rig.sender.receipts().isEmpty)
        #expect(rig.secrets.stored.isEmpty)
    }

    // MARK: - automatic sharing

    @Test("off, nothing is ever requested, after a crash or a week of looks")
    func offNothingIsEverRequested() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let conditions = SharingConditions(enabled: false)
        let builder = builder(for: rig)
        let scheduler = rig.scheduler(conditions) { builder.build($0, $1) }
        await scheduler.enable()
        await scheduler.noteCrash(incident: "incident-1", since: rig.clock.now)
        for _ in 0..<(7 * 24 * 4) {
            #expect(await scheduler.tick() == .off)
            rig.clock.advance(by: DiagnosticSharingPolicy.checkInterval)
        }
        #expect(rig.transport.requestCount == 0)
        #expect(builder.requests.isEmpty)
        #expect(DiagnosticSharingStateStore(layout: rig.layout).load() == nil)
    }

    @Test("on, a crash is sent once, after recording and processing end")
    func onACrashWaitsForRecordingToEnd() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let conditions = SharingConditions(enabled: true)
        conditions.isBusy = true
        let builder = builder(for: rig)
        let scheduler = rig.scheduler(conditions) { builder.build($0, $1) }
        let crashedLaunch = rig.clock.now.addingTimeInterval(-3_600)
        await scheduler.noteCrash(incident: "incident-1", since: crashedLaunch)

        #expect(await scheduler.tick() == .deferred(.busy))
        #expect(rig.transport.requestCount == 0)
        #expect(builder.requests.isEmpty)

        conditions.isBusy = false
        rig.clock.advance(by: 60)
        #expect(await scheduler.tick() == .ran)
        #expect(builder.requests.map(\.0) == [.crash])
        #expect(builder.requests.first?.1 == crashedLaunch)
        #expect(rig.transport.submissions.count == 1)
        #expect(await rig.sender.receipts().map(\.kind) == [.crash])

        await scheduler.noteCrash(incident: "incident-1", since: crashedLaunch)
        rig.clock.advance(by: 60)
        await scheduler.tick()
        #expect(rig.transport.submissions.count == 1)
    }

    @Test("on, Low Data Mode, an expensive network, or no network sends nothing")
    func onAConstrainedNetworkSendsNothing() async throws {
        for network in [
            DiagnosticNetworkCondition(isSatisfied: true, isConstrained: true),
            DiagnosticNetworkCondition(isSatisfied: true, isExpensive: true),
            DiagnosticNetworkCondition.unknown,
        ] {
            let rig = try Rig()
            defer { rig.remove() }
            let conditions = SharingConditions(enabled: true)
            conditions.network = network
            let builder = builder(for: rig)
            let scheduler = rig.scheduler(conditions) { builder.build($0, $1) }
            await scheduler.noteCrash(incident: "incident-1", since: rig.clock.now)
            for _ in 0..<(3 * 24 * 4) {
                await scheduler.tick()
                rig.clock.advance(by: DiagnosticSharingPolicy.checkInterval)
            }
            #expect(rig.transport.requestCount == 0)
            #expect(builder.requests.isEmpty)
        }
    }

    @Test("on, a daily report goes once a day with the events since the last confirmed one")
    func onADailyReportGoesOnceADay() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        rig.clock.setRandom(0)
        let conditions = SharingConditions(enabled: true)
        let builder = builder(for: rig)
        let scheduler = rig.scheduler(conditions) { builder.build($0, $1) }
        let enabledAt = rig.clock.now
        await scheduler.enable()

        // Nothing the first day.
        for _ in 0..<(24 * 4 - 1) {
            await scheduler.tick()
            rig.clock.advance(by: DiagnosticSharingPolicy.checkInterval)
        }
        #expect(builder.requests.isEmpty)

        rig.clock.advance(by: DiagnosticSharingPolicy.checkInterval)
        await scheduler.tick()
        #expect(builder.requests.map(\.0) == [.automatic])
        #expect(builder.requests.last?.1 == enabledAt)
        let firstCreated = rig.clock.now
        await scheduler.tick()
        #expect(rig.transport.submissions.count == 1)

        // A failed second day keeps the cut-off and queues the report.
        rig.transport.answer(next: .unavailable(status: 503, retryAfter: nil))
        rig.clock.advance(by: DiagnosticSharingPolicy.dailyInterval)
        await scheduler.tick()
        #expect(builder.requests.count == 2)
        #expect(builder.requests.last?.1 == firstCreated)
        #expect(await rig.sender.pending().count == 1)

        // Confirmed on a retry, which moves the cut-off to that report.
        let secondCreated = rig.clock.now
        rig.clock.advance(by: DiagnosticSendPolicy.maximumDelay)
        await scheduler.tick()
        #expect(await rig.sender.pending().isEmpty)
        #expect(DiagnosticSharingStateStore(layout: rig.layout).load()?.eventsSince == secondCreated)
        #expect(builder.requests.count == 2)
    }

    @Test("turning sharing off empties the outbox of automatic reports and keeps the person's")
    func turningSharingOffEmptiesTheAutomaticOutbox() async throws {
        let rig = try Rig([.unavailable(status: 503, retryAfter: nil), .unavailable(status: 503, retryAfter: nil)])
        defer { rig.remove() }
        let conditions = SharingConditions(enabled: true)
        let builder = builder(for: rig)
        let scheduler = rig.scheduler(conditions) { builder.build($0, $1) }
        let mine = try rig.report()
        _ = await rig.sender.send(mine)
        await scheduler.noteCrash(incident: "incident-1", since: rig.clock.now)
        await scheduler.tick()
        let queued = await rig.sender.pending()
        #expect(queued.map(\.automatic).sorted { !$0 && $1 } == [false, true])
        let automatic = try #require(queued.first { $0.automatic })

        conditions.isEnabled = false
        await scheduler.disable()
        #expect(await rig.sender.pending().map(\.reportID) == [mine.reportID])
        #expect(rig.secrets.secret(reportID: automatic.reportID) == nil)
        #expect(rig.secrets.secret(reportID: mine.reportID) != nil)
        // It had been attempted, so the service is asked to delete it too.
        #expect(rig.transport.deletions.map(\.id) == [automatic.reportID])
        #expect(DiagnosticSharingStateStore(layout: rig.layout).load() == nil)

        // While off, only the person's report is retried.
        rig.clock.advance(by: DiagnosticSendPolicy.maximumDelay)
        #expect(await scheduler.tick() == .off)
        #expect(rig.transport.submissions.last?.reportID == mine.reportID)
        #expect(builder.requests.map(\.0) == [.crash])
    }

    @Test("with no report builder connected, nothing is sent")
    func withNoBuilderNothingIsSent() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let conditions = SharingConditions(enabled: true)
        let scheduler = DiagnosticSharingScheduler(
            sender: rig.sender, layout: rig.layout, isEnabled: { conditions.isEnabled },
            isBusy: { false }, network: { .unmetered }, now: { [clock = rig.clock] in clock.now }
        )
        await scheduler.noteCrash(incident: "incident-1", since: rig.clock.now)
        rig.clock.advance(by: 3 * DiagnosticSharingPolicy.dailyInterval)
        await scheduler.tick()
        #expect(rig.transport.requestCount == 0)
        #expect(DiagnosticSharingStateStore(layout: rig.layout).load()?.pendingCrashes.isEmpty == true)
    }

    // MARK: - helpers

    static func eventText(under root: URL) throws -> String {
        let events = DiagnosticLayout(root: root).events
        let names = (try? FileManager.default.contentsOfDirectory(atPath: events.path)) ?? []
        return try names.sorted().map { try String(contentsOf: events.appendingPathComponent($0), encoding: .utf8) }
            .joined()
    }
}
