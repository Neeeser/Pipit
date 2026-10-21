import Foundation
import PipitCore

/// Sends reports, keeps the outbox and the receipts, and deletes sent reports
/// (`docs/DIAGNOSTICS.md`, Report service).
///
/// A report gets its ID and deletion secret before it is built, from
/// `prepareIdentity`. `send` writes the exact compressed body to `outbox/`
/// before the first attempt, so every retry sends the same bytes under the
/// same ID and the service answers a retry of a stored report as a replay
/// rather than storing it twice. A confirmed report moves to `sent.json`;
/// one the service will never take is dropped; one that met no answer, a
/// rate limit, or a server error waits with a jittered, doubling backoff and
/// is dropped after 7 days.
///
/// Best effort throughout, and an actor, so the disk and the network are
/// never touched on the main thread. Nothing here is logged but report IDs,
/// sizes, statuses, and outcomes: never a body, a secret, a note, or a
/// contact.
public actor DiagnosticReportSender: DiagnosticReportSending {
    private let outbox: DiagnosticOutbox
    private let receiptStore: DiagnosticReceiptStore
    private let transport: any DiagnosticReportTransport
    private let secrets: any DiagnosticDeletionSecrets
    private let diagnostics: DiagnosticLog
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    /// Report IDs with an attempt under way. An actor yields at every await,
    /// so a retry pass could otherwise pick up a report its first attempt is
    /// still sending.
    private var inFlight: Set<String> = []

    public init(
        layout: DiagnosticLayout,
        transport: any DiagnosticReportTransport,
        secrets: any DiagnosticDeletionSecrets,
        diagnostics: DiagnosticLog = .disabled,
        now: @escaping @Sendable () -> Date = { Date() },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.outbox = DiagnosticOutbox(layout: layout)
        self.receiptStore = DiagnosticReceiptStore(layout: layout)
        self.transport = transport
        self.secrets = secrets
        self.diagnostics = diagnostics
        self.now = now
        self.random = random
    }

    // MARK: - identity

    /// A new report ID and the hash of a new deletion secret, for the builder
    /// to stamp the report with. The secret goes into the Keychain under the
    /// ID, lowercase, and never leaves it except as a deletion code or a
    /// `DELETE`. It writes the Keychain, so a caller on the main actor calls
    /// it from a detached task.
    public nonisolated func prepareIdentity() -> (reportID: UUID, deletionSecretHash: String) {
        let reportID = UUID()
        let secret = secrets.generate()
        if !secrets.store(secret, reportID: reportID.uuidString.lowercased()) {
            Log.app.error(
                "report \(reportID.uuidString.lowercased(), privacy: .public): deletion secret not stored"
            )
        }
        return (reportID, secrets.hash(of: secret))
    }

    /// Forgets an identity whose report was not sent, such as one previewed
    /// and then closed.
    public nonisolated func discardIdentity(_ reportID: UUID) {
        secrets.remove(reportID: reportID.uuidString.lowercased())
    }

    // MARK: - sending

    /// Sends a report the person chose to send.
    public func send(_ report: DiagnosticReport) async -> DiagnosticSendOutcome {
        await send(report, automatic: false)
    }

    /// Sends a report. `automatic` marks one automatic sharing queued, which
    /// turning sharing off removes.
    public func send(_ report: DiagnosticReport, automatic: Bool) async -> DiagnosticSendOutcome {
        let reportID = report.reportID.lowercased()
        guard UUID(uuidString: reportID) != nil else {
            record(report.kind, bytes: 0, outcome: .rejected, status: nil)
            return .rejected(.invalidReport(error: "invalid_report_id"))
        }
        // A second send of the same report reuses the body already queued.
        // Encoding it again would give the service other bytes under the
        // same ID, which it refuses as a conflict.
        if let queued = outbox.entry(for: reportID) {
            return await attempt(queued, body: nil, isQueued: true)
        }
        guard DiagnosticReportValidator.violations(in: report).isEmpty, let json = try? report.encoded() else {
            record(report.kind, bytes: 0, outcome: .rejected, status: nil)
            secrets.remove(reportID: reportID)
            return .rejected(.invalidReport(error: nil))
        }
        // The builder's compressor, so the body is the one Export saved as
        // report.json.gz for the same report.
        guard let body = try? DiagnosticCompression.gzip(json) else {
            record(report.kind, bytes: 0, outcome: .failed, status: nil)
            secrets.remove(reportID: reportID)
            return .failed
        }
        guard body.count <= DiagnosticReportLimits.compressedBytes else {
            record(report.kind, bytes: body.count, outcome: .rejected, status: nil)
            secrets.remove(reportID: reportID)
            return .rejected(.tooLarge)
        }
        let entry = DiagnosticOutboxEntry(
            reportID: reportID, kind: report.kind, createdAt: report.createdAt, queuedAt: now(),
            automatic: automatic, bytes: body.count
        )
        do {
            try outbox.enqueue(entry, body: body)
        } catch {
            // Sent once anyway: the person asked for it, and what is lost is
            // only the retry.
            Log.app.error(
                "report \(reportID, privacy: .public) not queued: \(logSafeDescription(error), privacy: .public)")
            outbox.remove(reportID)
            return await attempt(entry, body: body, isQueued: false)
        }
        return await attempt(entry, body: body, isQueued: true)
    }

    /// Attempts every queued report whose wait is over. Reports the person
    /// sent always; automatic ones only when `includeAutomatic`. Stops at the
    /// first that meets no answer or a limit, since the next would too.
    /// Returns the entries the service confirmed.
    public func retryDue(includeAutomatic: Bool) async -> [DiagnosticOutboxEntry] {
        var confirmed: [DiagnosticOutboxEntry] = []
        for entry in outbox.entries() {
            let at = now()
            if entry.isExpired(now: at) {
                drop(entry, reason: "expired")
                continue
            }
            guard includeAutomatic || !entry.automatic, entry.nextAttemptAt <= at, !inFlight.contains(entry.reportID)
            else { continue }
            switch await attempt(entry, body: nil, isQueued: true) {
            case .sent: confirmed.append(entry)
            case .rejected: continue
            case .willRetry, .failed, .unavailable: return confirmed
            }
        }
        return confirmed
    }

    /// Removes every report automatic sharing queued, at once. One that was
    /// already attempted may have reached the service with its answer lost,
    /// so it is deleted there too, best effort; a 404 is the usual answer.
    public func discardAutomatic() async {
        for entry in outbox.entries() where entry.automatic {
            outbox.remove(entry.reportID)
            if entry.attempts > 0, let secret = secrets.secret(reportID: entry.reportID) {
                _ = await transport.delete(id: entry.reportID, secret: secret)
            }
            secrets.remove(reportID: entry.reportID)
        }
    }

    /// Removes every queued report and its secret. Clear Diagnostics calls
    /// this before it deletes the folder, so no secret outlives its report.
    public func discardOutbox() {
        for entry in outbox.entries() {
            outbox.remove(entry.reportID)
            secrets.remove(reportID: entry.reportID)
        }
        removeStrays()
    }

    /// Deletes what an interrupted write left in `outbox/`. Run at launch.
    public func removeStrays() {
        let receipts = Set(receiptStore.load().map(\.reportID))
        for reportID in outbox.removeStrays() where !receipts.contains(reportID) {
            secrets.remove(reportID: reportID)
        }
    }

    public func pending() -> [DiagnosticOutboxEntry] { outbox.entries() }

    // MARK: - sent reports

    /// Sent reports, newest first.
    public func receipts() -> [DiagnosticReceipt] { receiptStore.load() }

    /// `<reportID>.<deletion secret>`, or nil when the secret is not in the
    /// Keychain. Reading it can raise a Keychain prompt, which is why this is
    /// asked of the actor and not on the main thread.
    public func deletionCode(reportID: String) -> String? {
        secrets.secret(reportID: reportID.lowercased()).map {
            DiagnosticDeletionCode.make(reportID: reportID, secret: $0)
        }
    }

    /// Asks the service to delete a sent report. On `204` or `404` the
    /// receipt and the secret go too.
    public func deleteFromServer(reportID: String) async -> DiagnosticDeletionOutcome {
        let reportID = reportID.lowercased()
        guard let secret = secrets.secret(reportID: reportID) else { return .noSecret }
        let result = await transport.delete(id: reportID, secret: secret)
        guard result.isGone else {
            Log.app.notice(
                "report \(reportID, privacy: .public) not deleted: \(String(describing: result), privacy: .public)")
            return .failed
        }
        forget(reportID: reportID)
        return result == .deleted ? .deleted : .alreadyGone
    }

    /// Removes a receipt and its secret without asking the service.
    public func forget(reportID: String) {
        let reportID = reportID.lowercased()
        do {
            try receiptStore.remove(reportID: reportID)
        } catch {
            Log.app.error("receipt not removed: \(logSafeDescription(error), privacy: .public)")
        }
        secrets.remove(reportID: reportID)
    }

    /// Forgets every sent report: the receipts and their secrets. The reports
    /// stay on the server until they expire.
    public func forgetSentReports() {
        for receipt in receiptStore.load() { secrets.remove(reportID: receipt.reportID) }
        do {
            try receiptStore.removeAll()
        } catch {
            Log.app.error("receipts not removed: \(logSafeDescription(error), privacy: .public)")
        }
    }

    // MARK: - attempts

    private func attempt(_ entry: DiagnosticOutboxEntry, body: Data?, isQueued: Bool) async -> DiagnosticSendOutcome {
        let reportID = entry.reportID
        guard !inFlight.contains(reportID) else { return .willRetry(at: entry.nextAttemptAt) }
        guard let body = body ?? outbox.body(for: reportID) else {
            drop(entry, reason: "body missing")
            return .failed
        }
        inFlight.insert(reportID)
        defer { inFlight.remove(reportID) }

        let result = await transport.submit(body: body, reportID: reportID)
        let at = now()
        record(
            entry.kind, bytes: body.count, outcome: DiagnosticSendPolicy.eventOutcome(for: result),
            status: result.status)
        Log.app.info(
            "report \(reportID, privacy: .public): \(body.count) bytes, status \(result.status ?? 0), attempt \(entry.attempts + 1)"
        )

        switch DiagnosticSendPolicy.disposition(for: result) {
        case .confirmed(let service):
            let receipt = DiagnosticReceipt(
                reportID: reportID, kind: entry.kind, sentAt: at, receivedAt: service.receivedAt,
                expiresAt: service.expiresAt, bytes: body.count
            )
            do {
                try receiptStore.add(receipt)
            } catch {
                Log.app.error("receipt not saved: \(logSafeDescription(error), privacy: .public)")
            }
            outbox.remove(reportID)
            return .sent(receipt)
        case .dropped:
            outbox.remove(reportID)
            secrets.remove(reportID: reportID)
            return .rejected(Self.rejection(for: result))
        case .retry(let retryAfter):
            guard isQueued else {
                secrets.remove(reportID: reportID)
                return .failed
            }
            var updated = entry
            updated.attempts += 1
            guard !updated.isExpired(now: at) else {
                drop(updated, reason: "expired")
                return .failed
            }
            let delay = DiagnosticSendPolicy.retryDelay(
                afterAttempts: updated.attempts, retryAfter: retryAfter, random: random()
            )
            updated.nextAttemptAt = at.addingTimeInterval(delay)
            do {
                try outbox.update(updated)
            } catch {
                Log.app.error(
                    "report \(reportID, privacy: .public) not rescheduled: \(logSafeDescription(error), privacy: .public)"
                )
            }
            return .willRetry(at: updated.nextAttemptAt)
        }
    }

    private func drop(_ entry: DiagnosticOutboxEntry, reason: StaticString) {
        Log.app.notice("report \(entry.reportID, privacy: .public) dropped: \(reason, privacy: .public)")
        outbox.remove(entry.reportID)
        secrets.remove(reportID: entry.reportID)
    }

    private func record(
        _ kind: DiagnosticReport.Kind, bytes: Int, outcome: DiagnosticEvent.ReportOutcome, status: Int?
    ) {
        let eventKind = DiagnosticEvent.ReportKind(rawValue: kind.rawValue) ?? .user
        diagnostics.record(.reportSent(kind: eventKind, bytes: bytes, outcome: outcome, status: status))
    }

    static func rejection(for result: DiagnosticSubmitResult) -> DiagnosticSendRejection {
        switch result {
        case .invalid(let error): .invalidReport(error: error)
        case .conflict: .conflict
        case .tooLarge: .tooLarge
        case .unsupportedMediaType: .unsupportedMediaType
        case .unexpected(let status): .unexpectedStatus(status)
        case .accepted, .replayed, .rateLimited, .unavailable, .unreadableReceipt, .network:
            .unexpectedStatus(result.status ?? 0)
        }
    }
}
