import Foundation

/// What a report is assembled from, read before it is built.
///
/// The sections come from `DiagnosticSnapshot`; the events and crashes from
/// `~/Library/Logs/Pipit` through `DiagnosticLayout.storedEvents` and
/// `CrashReportScanner.stored`. Gathered once for a preview, so typing a note
/// rebuilds the report without reading the disk again.
public struct DiagnosticBundleContents: Sendable, Equatable {
    public var app: DiagnosticReport.App
    public var system: DiagnosticReport.System
    public var settings: [String: JSONValue]
    public var permissions: [String: String]
    public var models: [DiagnosticReport.Model]
    public var browserAddOns: [DiagnosticReport.BrowserAddOn]
    public var storage: DiagnosticReport.Storage
    public var recentFailures: [DiagnosticReport.RecentFailure]
    /// Every event on this Mac, oldest first.
    public var events: [DiagnosticEvent]
    /// Newest first, as `CrashReportScanner.stored` returns them.
    public var crashes: [CrashSummary]

    public init(
        app: DiagnosticReport.App, system: DiagnosticReport.System, settings: [String: JSONValue],
        permissions: [String: String], models: [DiagnosticReport.Model],
        browserAddOns: [DiagnosticReport.BrowserAddOn], storage: DiagnosticReport.Storage,
        recentFailures: [DiagnosticReport.RecentFailure], events: [DiagnosticEvent], crashes: [CrashSummary]
    ) {
        self.app = app
        self.system = system
        self.settings = settings
        self.permissions = permissions
        self.models = models
        self.browserAddOns = browserAddOns
        self.storage = storage
        self.recentFailures = recentFailures
        self.events = events
        self.crashes = crashes
    }
}

/// Who a report is, and what the person added to it.
///
/// The report ID and the deletion secret's hash are made by whoever sends the
/// report, before its first attempt, so a retry carries the same ones.
public struct DiagnosticBundleRequest: Sendable, Equatable {
    public var reportID: String
    public var kind: DiagnosticReport.Kind
    public var createdAt: Date
    public var deletionSecretHash: String
    /// Kept on a `user` report only, and only when it holds more than
    /// whitespace.
    public var note: String?
    public var contact: String?
    /// Events before this are left out, for the daily upload that sends what
    /// is new since the last one, and for a crash report, which starts at the
    /// crashed launch. They are not counted as omitted.
    public var eventsSince: Date?
    /// Crash summaries of crashes before this are left out, for the same two.
    public var crashesSince: Date?

    public init(
        reportID: String, kind: DiagnosticReport.Kind, createdAt: Date, deletionSecretHash: String,
        note: String? = nil, contact: String? = nil, eventsSince: Date? = nil, crashesSince: Date? = nil
    ) {
        self.reportID = reportID
        self.kind = kind
        self.createdAt = createdAt
        self.deletionSecretHash = deletionSecretHash
        self.note = note
        self.contact = contact
        self.eventsSince = eventsSince
        self.crashesSince = crashesSince
    }
}

/// How big a report is, before and after compression.
public struct DiagnosticReportSize: Sendable, Equatable {
    public var raw: Int
    public var compressed: Int

    public init(raw: Int, compressed: Int) {
        self.raw = raw
        self.compressed = compressed
    }
}

/// A built report, with the bytes it is exported and sent as.
public struct DiagnosticBundle: Sendable, Equatable {
    public let report: DiagnosticReport
    /// `report` as JSON, compact.
    public let json: Data
    /// `json` gzipped: the request body, byte for byte.
    public let gzipped: Data

    public var size: DiagnosticReportSize { DiagnosticReportSize(raw: json.count, compressed: gzipped.count) }
}

extension DiagnosticReport {
    /// The request body: this report as compact JSON, gzipped.
    public func gzippedJSON() throws -> Data {
        try DiagnosticCompression.gzip(try encoded())
    }

    /// The report's size as JSON and as the request body.
    public func measuredSize() throws -> DiagnosticReportSize {
        let json = try encoded()
        return DiagnosticReportSize(raw: json.count, compressed: try DiagnosticCompression.gzip(json).count)
    }
}

/// Assembles a report and refuses to produce one the server would reject.
public enum DiagnosticBundleBuilder {
    /// The limits a report is fitted to. The server's, except in a test that
    /// wants to see events left out without writing a megabyte of them.
    public struct Budget: Sendable, Equatable {
        public var compressedBytes: Int
        public var decompressedBytes: Int
        public var events: Int

        public init(compressedBytes: Int, decompressedBytes: Int, events: Int) {
            self.compressedBytes = compressedBytes
            self.decompressedBytes = decompressedBytes
            self.events = events
        }

        public static let server = Budget(
            compressedBytes: DiagnosticReportLimits.compressedBytes,
            decompressedBytes: DiagnosticReportLimits.decompressedBytes,
            events: DiagnosticReportLimits.events
        )
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The report breaks the contract. Nothing is produced.
        case invalid([DiagnosticReportViolation])
        /// Even with every event left out the report is over the budget.
        case tooLarge(DiagnosticReportSize)
    }

    /// The report for `request` from `contents`.
    ///
    /// Events are sent newest first in what fits: at most `budget.events`,
    /// then as many of the newest as keep the JSON and the gzipped body under
    /// their limits, with `summary.diagnostics.eventsOmitted` saying how many
    /// were left out. Event lines go out in time order. At most ten crashes,
    /// newest first, from `crashesSince` when it is set. The result passes `DiagnosticReportValidator` or this
    /// throws.
    public static func build(
        _ contents: DiagnosticBundleContents, request: DiagnosticBundleRequest, budget: Budget = .server
    ) throws -> DiagnosticBundle {
        let candidates = contents.events.filter { event in
            request.eventsSince.map { event.time >= $0 } ?? true
        }
        let lines = candidates.map(\.jsonValue).filter(passesTokenRule)
        let dropped = contents.events.reduce(0) { total, event in
            guard case .diagnosticsDropped(let count) = event.kind else { return total }
            return total + count * event.count
        }
        let base = DiagnosticReport(
            reportID: request.reportID,
            kind: request.kind,
            createdAt: request.createdAt,
            deletionSecretHash: request.deletionSecretHash,
            app: contents.app,
            system: contents.system,
            summary: DiagnosticReport.Summary(
                settings: contents.settings,
                permissions: contents.permissions,
                models: contents.models,
                browserAddOns: contents.browserAddOns,
                storage: contents.storage,
                recentFailures: contents.recentFailures,
                diagnostics: DiagnosticReport.Diagnostics(
                    eventsDropped: dropped, oldestEvent: contents.events.first?.time,
                    eventsIncluded: 0, eventsOmitted: 0
                )
            ),
            events: [],
            crashes: contents.crashes.filter { crash in
                request.crashesSince.map { crash.occurredAt >= $0 } ?? true
            }
            .prefix(DiagnosticReportLimits.crashes).map { crash in
                var crash = crash
                crash.frames = Array(crash.frames.prefix(DiagnosticReportLimits.framesPerCrash))
                return crash
            },
            note: request.kind == .user ? freeText(request.note) : nil,
            contact: request.kind == .user ? freeText(request.contact) : nil
        )

        var kept = min(lines.count, max(0, budget.events))
        while true {
            var report = base
            report.events = Array(lines.suffix(kept))
            report.summary.diagnostics.eventsIncluded = kept
            report.summary.diagnostics.eventsOmitted = lines.count - kept
            let json = try report.encoded()
            let gzipped = try DiagnosticCompression.gzip(json)
            if json.count <= budget.decompressedBytes, gzipped.count <= budget.compressedBytes {
                let violations = DiagnosticReportValidator.violations(in: report)
                guard violations.isEmpty else { throw Failure.invalid(violations) }
                return DiagnosticBundle(report: report, json: json, gzipped: gzipped)
            }
            guard kept > 0 else {
                throw Failure.tooLarge(DiagnosticReportSize(raw: json.count, compressed: gzipped.count))
            }
            // Shrink in proportion to how far over the larger overrun is, a
            // little further to land under rather than on the limit, and by
            // at least one so the loop ends.
            let ratio = min(
                Double(budget.compressedBytes) / Double(gzipped.count),
                Double(budget.decompressedBytes) / Double(json.count)
            )
            kept = min(kept - 1, Int(Double(kept) * ratio * 0.97))
            kept = max(0, kept)
        }
    }

    /// The person's own words, or nil when they wrote nothing.
    static func freeText(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// An event read from disk whose strings break the token rule would make
    /// the whole report invalid. Pipit wrote it, so this does not happen, but
    /// a damaged file is left out a line at a time rather than refused whole.
    static func passesTokenRule(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let text): DiagnosticTokenRule.accepts(text)
        case .array(let elements): elements.allSatisfy(passesTokenRule)
        case .object(let members):
            members.allSatisfy { DiagnosticTokenRule.accepts($0.key) && passesTokenRule($0.value) }
        case .null, .bool, .integer, .double: true
        }
    }
}

// MARK: - events as report values

extension DiagnosticEvent {
    /// The line this event is written as, as a JSON tree.
    ///
    /// Built directly rather than encoded and parsed back, which for twenty
    /// thousand events is most of the time a report takes to build. A test
    /// holds it equal to the encoder's line for every kind.
    var jsonValue: JSONValue {
        var line: [String: JSONValue] = [
            "v": .integer(Int64(Self.schemaVersion)),
            "t": .string(Self.timeStyle.format(time)),
            "launch": .string(launch.description),
            "kind": .string(kind.name),
        ]
        if let session { line["session"] = .string(session.description) }
        if let job { line["job"] = .string(job.description) }
        var payload: [String: JSONValue] = [:]
        for (key, value) in kind.fields {
            switch value {
            case .string(let text): payload[key] = .string(text)
            case .int(let number): payload[key] = .integer(Int64(number))
            // A whole double is written without a fraction, and read back
            // as an integer, so it is held as one here.
            case .double(let number): payload[key] = Int64(exactly: number).map(JSONValue.integer) ?? .double(number)
            case .bool(let flag): payload[key] = .bool(flag)
            }
        }
        line["p"] = .object(payload)
        if count > 1 { line["n"] = .integer(Int64(count)) }
        return .object(line)
    }
}

// MARK: - reading the log

extension DiagnosticLayout {
    /// Every event in `events/`, the app's and the native host's, and in
    /// `additionalFiles` (the Safari extension's, which lives in the app
    /// group), oldest first. A line that cannot be read is skipped. Two
    /// events at the same instant keep the order they were read in.
    public func storedEvents(additionalFiles: [URL] = []) -> [DiagnosticEvent] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: events.path)) ?? []
        let files =
            names.compactMap(EventFile.init(name:))
            .sorted { ($0.day, $0.family.rawValue, $0.part) < ($1.day, $1.family.rawValue, $1.part) }
            .map { events.appendingPathComponent($0.name) } + additionalFiles
        var read: [DiagnosticEvent] = []
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            read += DiagnosticEventCoding.events(in: data)
        }
        return read.enumerated()
            .sorted { $0.element.time != $1.element.time ? $0.element.time < $1.element.time : $0.offset < $1.offset }
            .map(\.element)
    }
}
