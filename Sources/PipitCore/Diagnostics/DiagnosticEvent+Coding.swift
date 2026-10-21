import Foundation

/// One payload value. The only shapes the contract allows.
enum DiagnosticValue: Hashable, Sendable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Boolean first: a JSON number never decodes as one, and a JSON
        // boolean never decodes as a number.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }

    /// A double for an event: finite, and rounded to the millisecond, which is
    /// finer than anything a duration here is read for.
    static func finite(_ value: Double) -> DiagnosticValue {
        guard value.isFinite else { return .double(0) }
        return .double((value * 1_000).rounded() / 1_000)
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var int: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    var double: Double? {
        switch self {
        case .double(let value): value
        case .int(let value): Double(value)
        case .string, .bool: nil
        }
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

// MARK: - payloads

extension DiagnosticEvent.Kind {
    /// The payload, in the contract's key order. An optional field that has no
    /// value is left out rather than written as null.
    var fields: [(String, DiagnosticValue)] {
        switch self {
        case .appLaunched(let launch):
            [
                ("version", .string(launch.version.value)), ("build", .string(launch.build.value)),
                ("commit", .string(launch.commit.value)), ("os", .string(launch.os.value)),
                ("osBuild", .string(launch.osBuild.value)), ("hardware", .string(launch.hardware.value)),
                ("arch", .string(launch.arch.rawValue)),
            ]
        case .appTerminated:
            []
        case .appPreviousExit(let exitClass, let previousLaunch):
            [("class", .string(exitClass.rawValue))]
                + (previousLaunch.map { [("previousLaunch", .string($0.description))] } ?? [])
        case .permissionState(let permission, let state):
            [("permission", .string(permission.rawValue)), ("state", .string(state.rawValue))]
        case .detectionMeeting(let source, let evidence, let browser):
            [("source", .string(source.rawValue)), ("evidence", .string(evidence.rawValue))]
                + (browser.map { [("browser", .string($0.rawValue))] } ?? [])
        case .sessionStarted(let source, let trigger, let segmentSeconds):
            [
                ("source", .string(source.rawValue)), ("trigger", .string(trigger.rawValue)),
                ("segmentSeconds", .finite(segmentSeconds)),
            ]
        case .sessionStopped(let trigger, let seconds, let segments):
            [("trigger", .string(trigger.rawValue)), ("seconds", .finite(seconds)), ("segments", .int(segments))]
        case .captureBound(let track, let transport, let sampleRate, let channels, let targets):
            [
                ("track", .string(track.rawValue)), ("transport", .string(transport.rawValue)),
                ("sampleRate", .finite(sampleRate)), ("channels", .int(channels)),
            ] + (targets.map { [("targets", .int($0))] } ?? [])
        case .captureRestarted(let track, let reason, let count):
            [("track", .string(track.rawValue)), ("reason", .string(reason.rawValue)), ("count", .int(count))]
        case .captureHealth(let track, let state):
            [("track", .string(track.rawValue)), ("state", .string(state.rawValue))]
        case .captureWarning(let code):
            [("code", .string(code.value))]
        case .processingStageStarted(let stage, let attempt):
            [("stage", .string(stage.rawValue)), ("attempt", .int(attempt))]
        case .processingStageFinished(let stage, let attempt, let seconds):
            [("stage", .string(stage.rawValue)), ("attempt", .int(attempt)), ("seconds", .finite(seconds))]
        case .processingStageFailed(let stage, let attempt, let code, let retryable):
            [
                ("stage", .string(stage.rawValue)), ("attempt", .int(attempt)),
                ("code", .string(code.rawValue)), ("retryable", .bool(retryable)),
            ]
        case .modelInstallStarted(let unit):
            [("unit", .string(unit.rawValue))]
        case .modelInstallFinished(let unit, let bytes, let seconds):
            [("unit", .string(unit.rawValue)), ("bytes", .int(Int(bytes))), ("seconds", .finite(seconds))]
        case .modelInstallFailed(let unit, let code):
            [("unit", .string(unit.rawValue)), ("code", .string(code.rawValue))]
        case .updateChecked(let outcome, let code):
            [("outcome", .string(outcome.rawValue))] + (code.map { [("code", .string($0.rawValue))] } ?? [])
        case .browserAddonConnected(let browser, let addonVersion, let hostVersion, let protocolVersion):
            [
                ("browser", .string(browser.rawValue)), ("addonVersion", .string(addonVersion.value)),
                ("hostVersion", .string(hostVersion.value)),
            ] + (protocolVersion.map { [("protocol", .int($0))] } ?? [])
        case .browserAddonDisconnected(let browser, let reason):
            [("browser", .string(browser.rawValue)), ("reason", .string(reason.rawValue))]
        case .browserConnectionRejected(let browser, let reason):
            (browser.map { [("browser", .string($0.rawValue))] } ?? []) + [("reason", .string(reason.rawValue))]
        case .browserMessageUnparsable(let browser):
            [("browser", .string(browser.rawValue))]
        case .nativeHostStarted(let browser):
            [("browser", .string(browser.rawValue))]
        case .nativeHostAppUnreachable(let code):
            [("code", .string(code.rawValue))]
        case .nativeHostExited(let reason, let relayed):
            [("reason", .string(reason.rawValue)), ("relayed", .int(relayed))]
        case .diagnosticsDropped(let count):
            [("count", .int(count))]
        case .reportSent(let kind, let bytes, let outcome, let status):
            [("kind", .string(kind.rawValue)), ("bytes", .int(bytes)), ("outcome", .string(outcome.rawValue))]
                + (status.map { [("status", .int($0))] } ?? [])
        }
    }

    /// Reads a kind back from its name and payload. Nil for a kind this build
    /// does not know or a payload that does not fit it, so a line from a newer
    /// build is skipped rather than misread.
    init?(name: String, payload: [String: DiagnosticValue]) {
        let reader = PayloadReader(payload: payload)
        guard let kind = Self.decode(name: name, reader) else { return nil }
        self = kind
    }

    // One case per kind, which is the length of the contract's table.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func decode(name: String, _ read: PayloadReader) -> Self? {
        switch name {
        case "app.launched":
            guard let arch = read.enumeration("arch", DiagnosticEvent.Architecture.self) else { return nil }
            return .appLaunched(
                DiagnosticEvent.AppLaunch(
                    version: read.string("version"), build: read.string("build"), commit: read.string("commit"),
                    os: read.string("os"), osBuild: read.string("osBuild"), hardware: read.string("hardware"),
                    arch: arch
                ))
        case "app.terminated":
            return .appTerminated
        case "app.previous_exit":
            guard let exitClass = read.enumeration("class", DiagnosticEvent.ExitClass.self) else { return nil }
            return .appPreviousExit(
                exitClass: exitClass,
                previousLaunch: read.string("previousLaunch").flatMap(DiagnosticLaunchID.init(string:))
            )
        case "permission.state":
            guard let permission = read.enumeration("permission", DiagnosticEvent.Permission.self),
                let state = read.enumeration("state", DiagnosticEvent.PermissionGrant.self)
            else { return nil }
            return .permissionState(permission: permission, state: state)
        case "detection.meeting":
            guard let source = read.enumeration("source", MeetingSource.self),
                let evidence = read.enumeration("evidence", DiagnosticEvent.Evidence.self)
            else { return nil }
            return .detectionMeeting(
                source: source, evidence: evidence, browser: read.enumeration("browser", BrowserKind.self)
            )
        case "session.started":
            guard let source = read.enumeration("source", MeetingSource.self),
                let trigger = read.enumeration("trigger", DiagnosticEvent.StartTrigger.self),
                let segmentSeconds = read.double("segmentSeconds")
            else { return nil }
            return .sessionStarted(source: source, trigger: trigger, segmentSeconds: segmentSeconds)
        case "session.stopped":
            guard let trigger = read.enumeration("trigger", DiagnosticEvent.StopTrigger.self),
                let seconds = read.double("seconds"), let segments = read.int("segments")
            else { return nil }
            return .sessionStopped(trigger: trigger, seconds: seconds, segments: segments)
        case "capture.bound":
            guard let track = read.enumeration("track", CaptureTrack.self),
                let transport = read.enumeration("transport", DiagnosticEvent.Transport.self),
                let sampleRate = read.double("sampleRate"), let channels = read.int("channels")
            else { return nil }
            return .captureBound(
                track: track, transport: transport, sampleRate: sampleRate, channels: channels,
                targets: read.int("targets")
            )
        case "capture.restarted":
            guard let track = read.enumeration("track", CaptureTrack.self),
                let reason = read.enumeration("reason", DiagnosticEvent.RestartReason.self),
                let count = read.int("count")
            else { return nil }
            return .captureRestarted(track: track, reason: reason, count: count)
        case "capture.health":
            guard let track = read.enumeration("track", CaptureTrack.self),
                let state = read.enumeration("state", CaptureHealthState.self)
            else { return nil }
            return .captureHealth(track: track, state: state)
        case "capture.warning":
            guard let code = read.string("code") else { return nil }
            return .captureWarning(code: .word(code))
        case "processing.stage_started":
            guard let stage = read.enumeration("stage", ProcessingState.self), let attempt = read.int("attempt")
            else { return nil }
            return .processingStageStarted(stage: stage, attempt: attempt)
        case "processing.stage_finished":
            guard let stage = read.enumeration("stage", ProcessingState.self), let attempt = read.int("attempt"),
                let seconds = read.double("seconds")
            else { return nil }
            return .processingStageFinished(stage: stage, attempt: attempt, seconds: seconds)
        case "processing.stage_failed":
            guard let stage = read.enumeration("stage", ProcessingState.self), let attempt = read.int("attempt"),
                let code = read.code("code"), let retryable = read.bool("retryable")
            else { return nil }
            return .processingStageFailed(stage: stage, attempt: attempt, code: code, retryable: retryable)
        case "model.install_started":
            guard let unit = read.enumeration("unit", LocalModelUnit.self) else { return nil }
            return .modelInstallStarted(unit: unit)
        case "model.install_finished":
            guard let unit = read.enumeration("unit", LocalModelUnit.self), let bytes = read.int("bytes"),
                let seconds = read.double("seconds")
            else { return nil }
            return .modelInstallFinished(unit: unit, bytes: Int64(bytes), seconds: seconds)
        case "model.install_failed":
            guard let unit = read.enumeration("unit", LocalModelUnit.self), let code = read.code("code")
            else { return nil }
            return .modelInstallFailed(unit: unit, code: code)
        case "update.checked":
            guard let outcome = read.enumeration("outcome", DiagnosticEvent.UpdateOutcome.self) else { return nil }
            return .updateChecked(outcome: outcome, code: read.code("code"))
        case "browser.addon_connected":
            guard let browser = read.enumeration("browser", BrowserKind.self) else { return nil }
            return .browserAddonConnected(
                browser: browser, addonVersion: .version(read.string("addonVersion")),
                hostVersion: .version(read.string("hostVersion")), protocolVersion: read.int("protocol")
            )
        case "browser.addon_disconnected":
            guard let browser = read.enumeration("browser", BrowserKind.self),
                let reason = read.enumeration("reason", DiagnosticEvent.DisconnectReason.self)
            else { return nil }
            return .browserAddonDisconnected(browser: browser, reason: reason)
        case "browser.connection_rejected":
            guard let reason = read.enumeration("reason", DiagnosticEvent.RejectionReason.self) else { return nil }
            return .browserConnectionRejected(browser: read.enumeration("browser", BrowserKind.self), reason: reason)
        case "browser.message_unparsable":
            guard let browser = read.enumeration("browser", BrowserKind.self) else { return nil }
            return .browserMessageUnparsable(browser: browser)
        case "nativehost.started":
            guard let browser = read.enumeration("browser", BrowserKind.self) else { return nil }
            return .nativeHostStarted(browser: browser)
        case "nativehost.app_unreachable":
            guard let code = read.code("code") else { return nil }
            return .nativeHostAppUnreachable(code: code)
        case "nativehost.exited":
            guard let reason = read.enumeration("reason", DiagnosticEvent.HostExitReason.self),
                let relayed = read.int("relayed")
            else { return nil }
            return .nativeHostExited(reason: reason, relayed: relayed)
        case "diagnostics.dropped":
            guard let count = read.int("count") else { return nil }
            return .diagnosticsDropped(count: count)
        case "report.sent":
            guard let kind = read.enumeration("kind", DiagnosticEvent.ReportKind.self),
                let bytes = read.int("bytes"),
                let outcome = read.enumeration("outcome", DiagnosticEvent.ReportOutcome.self)
            else { return nil }
            return .reportSent(kind: kind, bytes: bytes, outcome: outcome, status: read.int("status"))
        default:
            return nil
        }
    }
}

/// Typed reads over a decoded payload.
private struct PayloadReader {
    let payload: [String: DiagnosticValue]

    func string(_ key: String) -> String? { payload[key]?.string }
    func int(_ key: String) -> Int? { payload[key]?.int }
    func double(_ key: String) -> Double? { payload[key]?.double }
    func bool(_ key: String) -> Bool? { payload[key]?.bool }
    func code(_ key: String) -> DiagnosticCode? { string(key).map(DiagnosticCode.init(checked:)) }

    func enumeration<Value: RawRepresentable>(_ key: String, _ type: Value.Type) -> Value?
    where Value.RawValue == String {
        string(key).flatMap(Value.init(rawValue:))
    }
}

// MARK: - the line

extension DiagnosticEvent: Codable {
    private enum Keys: String, CodingKey {
        case version = "v"
        case time = "t"
        case launch
        case session
        case job
        case kind
        case payload = "p"
        case count = "n"
    }

    /// A payload key, which is any of the field names above.
    private struct FieldKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// UTC to the millisecond, `2026-10-21T03:18:16.123Z`.
    static let timeStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(Self.schemaVersion, forKey: .version)
        try container.encode(Self.timeStyle.format(time), forKey: .time)
        try container.encode(launch, forKey: .launch)
        try container.encodeIfPresent(session, forKey: .session)
        try container.encodeIfPresent(job, forKey: .job)
        try container.encode(kind.name, forKey: .kind)
        var payload = container.nestedContainer(keyedBy: FieldKey.self, forKey: .payload)
        for (key, value) in kind.fields {
            try payload.encode(value, forKey: FieldKey(stringValue: key))
        }
        if count > 1 { try container.encode(count, forKey: .count) }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container, debugDescription: "unsupported schema \(version)"
            )
        }
        let text = try container.decode(String.self, forKey: .time)
        guard let time = try? Self.timeStyle.parse(text) else {
            throw DecodingError.dataCorruptedError(forKey: .time, in: container, debugDescription: "bad time")
        }
        let name = try container.decode(String.self, forKey: .kind)
        let payload = try container.decodeIfPresent([String: DiagnosticValue].self, forKey: .payload) ?? [:]
        guard let kind = Kind(name: name, payload: payload) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown kind or payload"
            )
        }
        self.init(
            time: time,
            launch: try container.decode(DiagnosticLaunchID.self, forKey: .launch),
            session: try container.decodeIfPresent(DiagnosticSessionID.self, forKey: .session),
            job: try container.decodeIfPresent(DiagnosticJobID.self, forKey: .job),
            kind: kind,
            count: try container.decodeIfPresent(Int.self, forKey: .count) ?? 1
        )
    }
}

/// The coders every event line goes through.
public enum DiagnosticCoding {
    /// Keys sorted, so a line is the same bytes however the encoder orders a
    /// container, and slashes unescaped, though no value here holds one.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder { JSONDecoder() }

    /// One line, newline included. Nil only if encoding failed, which a value
    /// built from these types cannot do.
    public static func line(_ event: DiagnosticEvent, encoder: JSONEncoder) -> Data? {
        guard var data = try? encoder.encode(event) else { return nil }
        data.append(0x0A)
        return data
    }

    /// Every event a file holds. A line this build cannot read, including a
    /// last line cut off mid-write, is skipped.
    public static func events(in data: Data) -> [DiagnosticEvent] {
        let decoder = makeDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(DiagnosticEvent.self, from: Data($0)) }
    }
}
