import Foundation

/// Finds Pipit's crash reports in a DiagnosticReports folder and keeps their
/// reduced summaries in `crashes/` (`docs/DIAGNOSTICS.md`, Files on this Mac).
///
/// Every step is best effort. A folder that cannot be listed, a report that
/// cannot be read or reduced, and a summary that cannot be written are passed
/// over, and the scan returns what it could do. Nothing here throws, so a
/// crash report can never stop Pipit from launching.
public struct CrashReportScanner: Sendable {
    /// The most summaries `crashes/` keeps, newest first.
    public static let maximumKept = 10
    /// The oldest summary `crashes/` keeps.
    public static let maximumAge: TimeInterval = 90 * 24 * 60 * 60

    /// Where ReportCrash writes, `~/Library/Logs/DiagnosticReports`.
    public let reportsDirectory: URL
    /// `~/Library/Logs/Pipit/crashes`.
    public let crashesDirectory: URL

    public init(reportsDirectory: URL, crashesDirectory: URL) {
        self.reportsDirectory = reportsDirectory
        self.crashesDirectory = crashesDirectory
    }

    /// The real folders under `home`.
    public init(home: URL) {
        self.init(
            reportsDirectory: home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
            crashesDirectory: home.appendingPathComponent("Library/Logs/Pipit/crashes", isDirectory: true)
        )
    }

    /// The reduced reports of Pipit's processes modified after `since`, one
    /// per incident, newest first. Reads only; nothing is stored.
    public func scan(since: Date? = nil) -> [CrashRecord] {
        let candidates = Self.files(in: reportsDirectory).filter { file in
            guard Self.isCandidate(file.lastPathComponent) else { return false }
            guard let since else { return true }
            guard let modified = Self.modificationDate(file) else { return false }
            return modified > since
        }
        return Self.newestFirst(Self.unique(candidates.compactMap(CrashReportReducer.reduce(contentsOf:))))
    }

    /// The summaries already kept in `crashes/`, newest first. A file that
    /// cannot be read is skipped.
    public func stored() -> [CrashRecord] {
        let decoder = DiagnosticCoding.makeDecoder()
        let records = Self.files(in: crashesDirectory).compactMap { file -> CrashRecord? in
            guard Self.isStoredName(file.lastPathComponent), let data = try? Data(contentsOf: file) else {
                return nil
            }
            return try? decoder.decode(CrashRecord.self, from: data)
        }
        return Self.newestFirst(Self.unique(records))
    }

    /// Scans, keeps the reports not seen before, and applies the cap. Returns
    /// the records stored by this call, newest first.
    @discardableResult
    public func scanAndStore(since: Date? = nil, now: Date) -> [CrashRecord] {
        store(scan(since: since), now: now)
    }

    /// Writes the records whose incident `crashes/` does not hold yet, then
    /// trims `crashes/` to the ten newest within 90 days of `now`. Returns
    /// the records written that survived the trim.
    @discardableResult
    public func store(_ records: [CrashRecord], now: Date) -> [CrashRecord] {
        let known = Set(stored().map(\.incident))
        let encoder = DiagnosticCoding.makeFileEncoder()
        var written: [CrashRecord] = []
        for record in Self.unique(records) where !known.contains(record.incident) {
            guard isWithinAge(record, now: now), let data = try? encoder.encode(record) else { continue }
            if (try? AtomicFile.write(data, to: file(for: record.incident))) != nil {
                written.append(record)
            }
        }
        let kept = Set(trim(now: now).map(\.incident))
        return Self.newestFirst(written.filter { kept.contains($0.incident) })
    }

    /// Removes summaries past the age or count cap, and files in `crashes/`
    /// that are not summaries Pipit can read. Returns what is kept.
    @discardableResult
    public func trim(now: Date) -> [CrashRecord] {
        let decoder = DiagnosticCoding.makeDecoder()
        var readable: [CrashRecord] = []
        for file in Self.files(in: crashesDirectory) where Self.isStoredName(file.lastPathComponent) {
            guard let data = try? Data(contentsOf: file),
                let record = try? decoder.decode(CrashRecord.self, from: data),
                file.lastPathComponent == Self.fileName(for: record.incident)
            else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            readable.append(record)
        }
        let ordered = Self.newestFirst(readable)
        let kept = Array(ordered.filter { isWithinAge($0, now: now) }.prefix(Self.maximumKept))
        let keptIncidents = Set(kept.map(\.incident))
        for record in ordered where !keptIncidents.contains(record.incident) {
            try? FileManager.default.removeItem(at: file(for: record.incident))
        }
        return kept
    }

    public func file(for incident: String) -> URL {
        crashesDirectory.appendingPathComponent(Self.fileName(for: incident))
    }

    // MARK: helpers

    private func isWithinAge(_ record: CrashRecord, now: Date) -> Bool {
        now.timeIntervalSince(record.summary.occurredAt) <= Self.maximumAge
    }

    static func fileName(for incident: String) -> String { incident + ".json" }

    /// `<executable>-<date>.ips` for one of Pipit's executables. The header
    /// decides whose report it is; the name only saves reading the others.
    static func isCandidate(_ name: String) -> Bool {
        guard name.hasSuffix(".ips") else { return false }
        return PipitProcess.allCases.contains { name.hasPrefix($0.executableName + "-") }
    }

    /// `<incident>.json`, which leaves out the hidden temporary files an
    /// interrupted atomic write can leave behind.
    private static func isStoredName(_ name: String) -> Bool {
        name.hasSuffix(".json") && !name.hasPrefix(".")
    }

    private static func files(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ))?.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true } ?? []
    }

    private static func modificationDate(_ file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func unique(_ records: [CrashRecord]) -> [CrashRecord] {
        var seen = Set<String>()
        return records.filter { seen.insert($0.incident).inserted }
    }

    /// Newest first, and by incident between two from the same instant, so
    /// the order does not depend on the order a folder was listed in.
    private static func newestFirst(_ records: [CrashRecord]) -> [CrashRecord] {
        records.sorted {
            $0.summary.occurredAt != $1.summary.occurredAt
                ? $0.summary.occurredAt > $1.summary.occurredAt : $0.incident < $1.incident
        }
    }
}
