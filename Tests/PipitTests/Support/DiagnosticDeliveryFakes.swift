import Foundation
import PipitCore

/// A report service that answers from a script and remembers every request.
///
/// `submit` takes the next scripted answer, and once the script runs out
/// answers `fallback`, or 201 with a receipt for the report it was sent.
/// Nothing leaves the process.
final class FakeReportTransport: DiagnosticReportTransport, @unchecked Sendable {
    struct Submission: Equatable {
        var reportID: String
        var body: Data
    }

    private let lock = NSLock()
    private var script: [DiagnosticSubmitResult]
    private var submitted: [Submission] = []
    private var deleted: [(id: String, secret: String)] = []
    private var looked: [(id: String, secret: String)] = []
    var deleteAnswer: DiagnosticDeleteResult = .deleted
    var fallback: DiagnosticSubmitResult?

    init(_ script: [DiagnosticSubmitResult] = []) {
        self.script = script
    }

    var submissions: [Submission] { lock.withLock { submitted } }
    var deletions: [(id: String, secret: String)] { lock.withLock { deleted } }
    /// Every request of any kind.
    var requestCount: Int { lock.withLock { submitted.count + deleted.count + looked.count } }

    func answer(next result: DiagnosticSubmitResult) {
        lock.withLock { script.append(result) }
    }

    func submit(body: Data, reportID: String) async -> DiagnosticSubmitResult {
        lock.withLock {
            submitted.append(Submission(reportID: reportID, body: body))
            if !script.isEmpty { return script.removeFirst() }
            return fallback ?? .accepted(Self.receipt(reportID))
        }
    }

    func status(id: String, secret: String) async -> DiagnosticLookupResult {
        lock.withLock { looked.append((id, secret)) }
        return .notFound
    }

    func delete(id: String, secret: String) async -> DiagnosticDeleteResult {
        lock.withLock {
            deleted.append((id, secret))
            return deleteAnswer
        }
    }

    static func receipt(_ reportID: String) -> DiagnosticServiceReceipt {
        DiagnosticServiceReceipt(
            reportID: reportID,
            receivedAt: DiagnosticDeliveryFixtures.received,
            expiresAt: DiagnosticDeliveryFixtures.received.addingTimeInterval(90 * 86_400)
        )
    }
}

/// Deletion secrets held in memory, standing in for the Keychain.
///
/// The hash is a stand-in too: base64url of the secret's bytes reversed,
/// which is 43 characters for a 32-byte secret like the real one. The real
/// hash is tested against the fixture's vector where CryptoKit exists.
final class InMemoryDeletionSecrets: DiagnosticDeletionSecrets, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private var counter = 0

    var stored: [String: String] { lock.withLock { items } }

    func generate() -> String {
        lock.withLock {
            counter += 1
            var bytes = [UInt8](repeating: 0, count: 32)
            bytes[0] = UInt8(truncatingIfNeeded: counter)
            bytes[1] = UInt8(truncatingIfNeeded: counter >> 8)
            for index in 2..<32 { bytes[index] = UInt8(truncatingIfNeeded: index &* 7 &+ counter) }
            return DiagnosticBase64URL.encode(Data(bytes))
        }
    }

    func hash(of secret: String) -> String {
        DiagnosticBase64URL.encode(Data(Data(secret.utf8).prefix(32).reversed()))
    }

    func store(_ secret: String, reportID: String) -> Bool {
        lock.withLock { items[reportID.lowercased()] = secret }
        return true
    }

    func secret(reportID: String) -> String? {
        lock.withLock { items[reportID.lowercased()] }
    }

    func remove(reportID: String) -> Bool {
        _ = lock.withLock { items.removeValue(forKey: reportID.lowercased()) }
        return true
    }
}

/// Clock and dice a test turns by hand.
final class ManualDeliveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var roll: Double = 0.5

    init(_ start: Date = DiagnosticDeliveryFixtures.start) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    func setRandom(_ value: Double) { lock.withLock { roll = value } }

    var random: Double { lock.withLock { roll } }
}

/// Whether Pipit is busy, the network, and the setting, for a scheduler test.
final class SharingConditions: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool
    private var busy = false
    private var condition = DiagnosticNetworkCondition.unmetered

    init(enabled: Bool) { self.enabled = enabled }

    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    var isBusy: Bool {
        get { lock.withLock { busy } }
        set { lock.withLock { busy = newValue } }
    }

    var network: DiagnosticNetworkCondition {
        get { lock.withLock { condition } }
        set { lock.withLock { condition = newValue } }
    }
}

enum DiagnosticDeliveryFixtures {
    static let start = DiagnosticsFixtures.utc("2026-10-21T09:00:00Z")
    static let received = DiagnosticsFixtures.utc("2026-10-21T09:00:01Z")

    /// The fixture report under a new identity and kind, valid to send.
    static func report(
        kind: DiagnosticReport.Kind = .user, reportID: UUID = UUID(), hash: String? = nil, createdAt: Date = start
    ) throws -> DiagnosticReport {
        var report = try DiagnosticReport.decode(Data(contentsOf: DiagnosticsFixtures.report))
        report.reportID = reportID.uuidString.lowercased()
        report.kind = kind
        report.createdAt = createdAt
        if let hash { report.deletionSecretHash = hash }
        if kind != .user {
            report.note = nil
            report.contact = nil
        }
        return report
    }
}
