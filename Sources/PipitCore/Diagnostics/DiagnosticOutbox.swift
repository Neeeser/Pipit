import Foundation

/// One report waiting for the service to confirm it.
///
/// Kept in `outbox/<reportID>.state.json` beside the exact body in
/// `outbox/<reportID>.json.gz`. Nothing here is a secret or free text.
public struct DiagnosticOutboxEntry: Codable, Sendable, Equatable {
    public var reportID: String
    public var kind: DiagnosticReport.Kind
    /// The report's `createdAt`. A confirmed daily report moves the next
    /// one's cut-off here.
    public var createdAt: Date
    /// When the body was written. Dropped `DiagnosticOutbox.maximumAge` later.
    public var queuedAt: Date
    /// Queued by automatic sharing rather than by the person pressing Send.
    /// Turning automatic sharing off removes these.
    public var automatic: Bool
    /// Compressed size.
    public var bytes: Int
    /// Attempts made so far.
    public var attempts: Int
    public var nextAttemptAt: Date

    public init(
        reportID: String, kind: DiagnosticReport.Kind, createdAt: Date, queuedAt: Date, automatic: Bool, bytes: Int,
        attempts: Int = 0, nextAttemptAt: Date? = nil
    ) {
        self.reportID = reportID.lowercased()
        self.kind = kind
        self.createdAt = createdAt
        self.queuedAt = queuedAt
        self.automatic = automatic
        self.bytes = bytes
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt ?? queuedAt
    }

    public func isExpired(now: Date) -> Bool {
        now.timeIntervalSince(queuedAt) >= DiagnosticOutbox.maximumAge
    }
}

/// `outbox/`: the bodies of reports not yet confirmed, and what is known
/// about each (`docs/DIAGNOSTICS.md`, Files on this Mac).
///
/// A body is written before its first attempt and never changed, so every
/// retry sends the same bytes under the same ID, which is what lets the
/// service answer a retry of a stored report as a replay. Not safe for two
/// writers at once; `DiagnosticReportSender` is the only one.
public struct DiagnosticOutbox: Sendable {
    /// A report still unconfirmed this long after it was queued is dropped.
    public static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    static let bodySuffix = ".json.gz"
    static let stateSuffix = ".state.json"

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public init(layout: DiagnosticLayout) { self.init(directory: layout.outbox) }

    /// Nil for an ID that is not a UUID, so no path is ever built from
    /// anything else.
    public func bodyFile(for reportID: String) -> URL? {
        guard UUID(uuidString: reportID) != nil else { return nil }
        return directory.appendingPathComponent(reportID.lowercased() + Self.bodySuffix)
    }

    func stateFile(for reportID: String) -> URL? {
        guard UUID(uuidString: reportID) != nil else { return nil }
        return directory.appendingPathComponent(reportID.lowercased() + Self.stateSuffix)
    }

    /// Writes the body, then the entry. A crash between the two leaves a body
    /// without an entry, which `entries` ignores and `removeStrays` deletes.
    public func enqueue(_ entry: DiagnosticOutboxEntry, body: Data) throws {
        guard let bodyFile = bodyFile(for: entry.reportID) else { throw CocoaError(.fileWriteInvalidFileName) }
        try AtomicFile.write(body, to: bodyFile)
        try update(entry)
    }

    /// Rewrites an entry's state. The body stays as it was written.
    public func update(_ entry: DiagnosticOutboxEntry) throws {
        guard let stateFile = stateFile(for: entry.reportID) else { throw CocoaError(.fileWriteInvalidFileName) }
        try AtomicFile.write(try DiagnosticCoding.makeFileEncoder().encode(entry), to: stateFile)
    }

    public func entry(for reportID: String) -> DiagnosticOutboxEntry? {
        guard let stateFile = stateFile(for: reportID), let bodyFile = bodyFile(for: reportID),
            FileManager.default.fileExists(atPath: bodyFile.path),
            let data = try? Data(contentsOf: stateFile),
            let entry = try? DiagnosticCoding.makeDecoder().decode(DiagnosticOutboxEntry.self, from: data),
            entry.reportID == reportID.lowercased()
        else { return nil }
        return entry
    }

    /// Every entry with a body, oldest first.
    public func entries() -> [DiagnosticOutboxEntry] {
        reportIDs(suffix: Self.stateSuffix).compactMap(entry(for:)).sorted { lhs, rhs in
            lhs.queuedAt == rhs.queuedAt ? lhs.reportID < rhs.reportID : lhs.queuedAt < rhs.queuedAt
        }
    }

    /// The exact bytes the entry was queued with.
    public func body(for reportID: String) -> Data? {
        bodyFile(for: reportID).flatMap { try? Data(contentsOf: $0) }
    }

    public func remove(_ reportID: String) {
        for file in [stateFile(for: reportID), bodyFile(for: reportID)].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Deletes a body without an entry, an entry without a body, and the
    /// temporary files of an interrupted write. Returns the report IDs whose
    /// files were removed, so their deletion secrets can go too.
    @discardableResult
    public func removeStrays() -> [String] {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        let known = Set(entries().map(\.reportID))
        var removed: Set<String> = []
        for name in names {
            let id = Self.reportID(in: name)
            if let id, known.contains(id) { continue }
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            if let id { removed.insert(id) }
        }
        return removed.sorted()
    }

    private func reportIDs(suffix: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(suffix) else { return nil }
            return Self.reportID(in: name)
        }
    }

    /// The report ID a body or state file is named for.
    static func reportID(in name: String) -> String? {
        for suffix in [bodySuffix, stateSuffix] where name.hasSuffix(suffix) {
            let stem = String(name.dropLast(suffix.count))
            guard UUID(uuidString: stem) != nil, stem == stem.lowercased() else { return nil }
            return stem
        }
        return nil
    }
}
