import Foundation

/// A diagnostic report, schema 1 (`docs/DIAGNOSTICS.md`, Report format).
///
/// The fixture `Tests/Fixtures/Diagnostics/report-v1.json` decodes into this
/// type and encodes back to the same JSON, and the website validates the same
/// file, so a change here is a change to the contract. Event lines are carried
/// as `JSONValue` because the bundle builder passes them through from disk as
/// they were written, already checked when they were.
public struct DiagnosticReport: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public enum Kind: String, Codable, Sendable {
        /// Report a Problem.
        case user
        /// Sent from the crash prompt.
        case crash
        /// The daily upload.
        case automatic
    }

    public struct App: Codable, Sendable, Equatable {
        public var version: String
        public var build: Int
        /// 40 hex characters, or `unknown`.
        public var commit: String
        public var channel: String
        public var configuration: String

        public init(version: String, build: Int, commit: String, channel: String, configuration: String) {
            self.version = version
            self.build = build
            self.commit = commit
            self.channel = channel
            self.configuration = configuration
        }
    }

    public struct System: Codable, Sendable, Equatable {
        public var os: String
        public var osBuild: String
        public var hardware: String
        public var arch: String
        public var memoryGB: Int
        public var cpuCores: Int
        /// A bucket such as `20-100GB`, never a byte count.
        public var freeDisk: String
        public var language: String

        public init(
            os: String, osBuild: String, hardware: String, arch: String, memoryGB: Int, cpuCores: Int,
            freeDisk: String, language: String
        ) {
            self.os = os
            self.osBuild = osBuild
            self.hardware = hardware
            self.arch = arch
            self.memoryGB = memoryGB
            self.cpuCores = cpuCores
            self.freeDisk = freeDisk
            self.language = language
        }
    }

    public struct Model: Codable, Sendable, Equatable {
        public var unit: String
        public var state: String
        public var revision: String?
        public var bytes: Int?

        public init(unit: String, state: String, revision: String? = nil, bytes: Int? = nil) {
            self.unit = unit
            self.state = state
            self.revision = revision
            self.bytes = bytes
        }
    }

    public struct BrowserAddOn: Codable, Sendable, Equatable {
        public var browser: String
        /// `on`, `off`, or `disconnected`.
        public var state: String
        public var addonVersion: String?
        public var hostVersion: String?
        public var `protocol`: Int?
        /// Whether the browser's native messaging host manifest is in place;
        /// for Chrome, whether any Chromium browser's is.
        public var hostManifest: Bool?
        /// Chrome's row only: each Chromium browser on this Mac, as a token
        /// such as `chrome_beta`, and whether its own manifest is in place.
        /// Each reads manifests from its own folder only.
        public var chromiumHostManifests: [String: Bool]?

        public init(
            browser: String, state: String, addonVersion: String? = nil, hostVersion: String? = nil,
            protocol: Int? = nil, hostManifest: Bool? = nil, chromiumHostManifests: [String: Bool]? = nil
        ) {
            self.browser = browser
            self.state = state
            self.addonVersion = addonVersion
            self.hostVersion = hostVersion
            self.protocol = `protocol`
            self.hostManifest = hostManifest
            self.chromiumHostManifests = chromiumHostManifests
        }
    }

    public struct Storage: Codable, Sendable, Equatable {
        public var meetings: Int
        public var freeDisk: String

        public init(meetings: Int, freeDisk: String) {
            self.meetings = meetings
            self.freeDisk = freeDisk
        }
    }

    public struct RecentFailure: Codable, Sendable, Equatable {
        public var stage: String
        public var code: String
        public var retryable: Bool
        public var attempts: Int
        public var at: Date

        public init(stage: String, code: String, retryable: Bool, attempts: Int, at: Date) {
            self.stage = stage
            self.code = code
            self.retryable = retryable
            self.attempts = attempts
            self.at = at
        }
    }

    public struct Diagnostics: Codable, Sendable, Equatable {
        public var eventsDropped: Int
        /// Left out when the log holds no events.
        public var oldestEvent: Date?
        public var eventsIncluded: Int
        public var eventsOmitted: Int

        public init(eventsDropped: Int, oldestEvent: Date?, eventsIncluded: Int, eventsOmitted: Int) {
            self.eventsDropped = eventsDropped
            self.oldestEvent = oldestEvent
            self.eventsIncluded = eventsIncluded
            self.eventsOmitted = eventsOmitted
        }
    }

    public struct Summary: Codable, Sendable, Equatable {
        /// Settings by name. Values are enum raw values, numbers, and
        /// booleans; the set of names grows with Settings, so it is not fixed
        /// here.
        public var settings: [String: JSONValue]
        /// Permission name to state, both from `permission.state`.
        public var permissions: [String: String]
        public var models: [Model]
        public var browserAddOns: [BrowserAddOn]
        public var storage: Storage
        public var recentFailures: [RecentFailure]
        public var diagnostics: Diagnostics

        public init(
            settings: [String: JSONValue], permissions: [String: String], models: [Model],
            browserAddOns: [BrowserAddOn], storage: Storage, recentFailures: [RecentFailure],
            diagnostics: Diagnostics
        ) {
            self.settings = settings
            self.permissions = permissions
            self.models = models
            self.browserAddOns = browserAddOns
            self.storage = storage
            self.recentFailures = recentFailures
            self.diagnostics = diagnostics
        }
    }

    public var schemaVersion: Int
    /// A random UUID, equal to the `Idempotency-Key` header.
    public var reportID: String
    public var kind: Kind
    public var createdAt: Date
    /// base64url(SHA-256(UTF-8 deletion secret)), 43 characters.
    public var deletionSecretHash: String
    public var app: App
    public var system: System
    public var summary: Summary
    /// Event lines as they were written, each a JSON object.
    public var events: [JSONValue]
    public var crashes: [CrashSummary]
    /// The person's own words, on a `user` report only.
    public var note: String?
    /// An address to answer at, on a `user` report only.
    public var contact: String?

    public init(
        reportID: String, kind: Kind, createdAt: Date, deletionSecretHash: String, app: App, system: System,
        summary: Summary, events: [JSONValue], crashes: [CrashSummary], note: String? = nil,
        contact: String? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.reportID = reportID
        self.kind = kind
        self.createdAt = createdAt
        self.deletionSecretHash = deletionSecretHash
        self.app = app
        self.system = system
        self.summary = summary
        self.events = events
        self.crashes = crashes
        self.note = note
        self.contact = contact
    }

    /// The JSON a report is sent and exported as, before compression.
    public func encoded() throws -> Data {
        try DiagnosticCoding.makeReportEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> DiagnosticReport {
        try DiagnosticCoding.makeDecoder().decode(DiagnosticReport.self, from: data)
    }
}

/// What the report service would refuse in a report. The app checks a report
/// before export or send with `DiagnosticReportValidator`, which applies the
/// same rules the server does.
public enum DiagnosticReportViolation: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    /// A string, or an object key, that breaks `DiagnosticTokenRule`. The
    /// path names where, as `crashes[0].images[1].name`; the value is never
    /// repeated, because it is what the rule exists to keep out.
    case token(path: String)
    case tooManyEvents(Int)
    case eventNotAnObject(index: Int)
    case tooManyCrashes(Int)
    case tooManyFrames(crash: Int, count: Int)
    /// A note or contact on a report that is not `user`.
    case freeTextNotAllowed
    case noteTooLong(Int)
    case contactTooLong(Int)
    /// More than `DiagnosticReportLimits.decompressedBytes` before compression.
    case tooLarge(bytes: Int)
    case notEncodable
}

public enum DiagnosticReportLimits {
    public static let compressedBytes = 1_048_576
    public static let decompressedBytes = 8 * 1024 * 1024
    public static let events = 20_000
    public static let crashes = 10
    public static let framesPerCrash = 128
    /// Counted in UTF-16 code units, as the server's JavaScript counts a
    /// string's length. That is never fewer than the characters a person sees,
    /// so a note the app accepts is one the server accepts.
    public static let noteLength = 4000
    public static let contactLength = 254
}

/// Checks a report against the token rule and the limits before it leaves
/// the Mac.
public enum DiagnosticReportValidator {
    /// The fields exempt from the token rule, at the top level only.
    static let freeTextKeys: Set<String> = ["note", "contact"]

    /// Every violation in `report`, empty for a report the server accepts.
    public static func violations(in report: DiagnosticReport) -> [DiagnosticReportViolation] {
        var found: [DiagnosticReportViolation] = []
        if report.schemaVersion != DiagnosticReport.schemaVersion {
            found.append(.unsupportedSchema(report.schemaVersion))
        }
        if report.events.count > DiagnosticReportLimits.events {
            found.append(.tooManyEvents(report.events.count))
        }
        for (index, event) in report.events.enumerated() where event.objectValue == nil {
            found.append(.eventNotAnObject(index: index))
        }
        if report.crashes.count > DiagnosticReportLimits.crashes {
            found.append(.tooManyCrashes(report.crashes.count))
        }
        for (index, crash) in report.crashes.enumerated()
        where crash.frames.count > DiagnosticReportLimits.framesPerCrash {
            found.append(.tooManyFrames(crash: index, count: crash.frames.count))
        }
        if report.kind != .user, report.note != nil || report.contact != nil {
            found.append(.freeTextNotAllowed)
        }
        if let note = report.note, note.utf16.count > DiagnosticReportLimits.noteLength {
            found.append(.noteTooLong(note.utf16.count))
        }
        if let contact = report.contact, contact.utf16.count > DiagnosticReportLimits.contactLength {
            found.append(.contactTooLong(contact.utf16.count))
        }

        // The rule is applied to the JSON that would be sent, not to the
        // Swift values, so a field added later is covered without a change
        // here.
        guard let data = try? report.encoded(), let tree = JSONValue.parse(data) else {
            return found + [.notEncodable]
        }
        if data.count > DiagnosticReportLimits.decompressedBytes {
            found.append(.tooLarge(bytes: data.count))
        }
        for (key, value) in (tree.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            if !DiagnosticTokenRule.accepts(key) {
                found.append(.token(path: "?"))
            } else if !freeTextKeys.contains(key) {
                tokenViolations(in: value, path: key, into: &found)
            }
        }
        return found
    }

    /// Throws the first violation, for a caller that only needs to know
    /// whether the report may go.
    public static func validate(_ report: DiagnosticReport) throws {
        if let first = violations(in: report).first { throw first }
    }

    private static func tokenViolations(
        in value: JSONValue, path: String, into found: inout [DiagnosticReportViolation]
    ) {
        switch value {
        case .string(let text):
            if !DiagnosticTokenRule.accepts(text) { found.append(.token(path: path)) }
        case .array(let elements):
            for (index, element) in elements.enumerated() {
                tokenViolations(in: element, path: "\(path)[\(index)]", into: &found)
            }
        case .object(let members):
            for (key, member) in members.sorted(by: { $0.key < $1.key }) {
                guard DiagnosticTokenRule.accepts(key) else {
                    found.append(.token(path: "\(path).?"))
                    continue
                }
                tokenViolations(in: member, path: "\(path).\(key)", into: &found)
            }
        case .null, .bool, .integer, .double:
            break
        }
    }
}
