import Foundation

/// A report the service confirmed, as `sent.json` keeps it. What Settings
/// lists under Sent reports. The deletion secret is in the Keychain, never
/// here.
public struct DiagnosticReceipt: Codable, Sendable, Equatable, Identifiable {
    public var reportID: String
    public var kind: DiagnosticReport.Kind
    /// When this Mac had the confirmation.
    public var sentAt: Date
    /// The service's own times.
    public var receivedAt: Date
    public var expiresAt: Date
    /// Compressed size.
    public var bytes: Int

    public init(
        reportID: String, kind: DiagnosticReport.Kind, sentAt: Date, receivedAt: Date, expiresAt: Date, bytes: Int
    ) {
        self.reportID = reportID.lowercased()
        self.kind = kind
        self.sentAt = sentAt
        self.receivedAt = receivedAt
        self.expiresAt = expiresAt
        self.bytes = bytes
    }

    public var id: String { reportID }
}

/// Reads and writes `sent.json`: `{"receipts": [...]}`, newest first.
///
/// Kept until the person removes a receipt, deletes the report, or chooses to
/// forget sent reports. Clear Diagnostics leaves it, because it is what the
/// deletion codes are listed from.
public struct DiagnosticReceiptStore: Sendable {
    public let file: URL

    public init(file: URL) { self.file = file }

    public init(layout: DiagnosticLayout) { self.init(file: layout.sentReceipts) }

    private struct Document: Codable {
        var receipts: [DiagnosticReceipt]
    }

    /// Every receipt, newest first. A damaged file reads as none rather than
    /// failing whatever asked.
    public func load() -> [DiagnosticReceipt] {
        guard let data = try? Data(contentsOf: file),
            let document = try? DiagnosticCoding.makeDecoder().decode(Document.self, from: data)
        else { return [] }
        return Self.ordered(document.receipts)
    }

    /// Adds a receipt, replacing one with the same report ID.
    public func add(_ receipt: DiagnosticReceipt) throws {
        var receipts = load().filter { $0.reportID != receipt.reportID }
        receipts.append(receipt)
        try save(receipts)
    }

    public func remove(reportID: String) throws {
        let receipts = load()
        let kept = receipts.filter { $0.reportID != reportID.lowercased() }
        guard kept.count != receipts.count else { return }
        try save(kept)
    }

    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    private func save(_ receipts: [DiagnosticReceipt]) throws {
        let data = try DiagnosticCoding.makeFileEncoder().encode(Document(receipts: Self.ordered(receipts)))
        try AtomicFile.write(data, to: file)
    }

    private static func ordered(_ receipts: [DiagnosticReceipt]) -> [DiagnosticReceipt] {
        receipts.sorted { lhs, rhs in
            lhs.sentAt == rhs.sentAt ? lhs.reportID < rhs.reportID : lhs.sentAt > rhs.sentAt
        }
    }
}
