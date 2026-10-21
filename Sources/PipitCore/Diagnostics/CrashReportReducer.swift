import Foundation

/// Reads one of Apple's `.ips` crash reports and keeps what
/// `docs/DIAGNOSTICS.md` allows.
///
/// An `.ips` is two JSON documents: a header object on the first line, and
/// the report after it. ReportCrash writes `bug_type` 309 for a crash, which is
/// the only kind read here. Hang and spin reports carry other bug types and a
/// layout Apple does not document, and spindump writes them under
/// `/Library/Logs/DiagnosticReports` rather than the user's folder, so none of
/// them is guessed at. A report that is not JSON, is cut short, is not one of
/// Pipit's processes, or says it is not fatal reduces to nil. Nothing here
/// throws.
///
/// The reduction is an allowlist. Only the fields below are read, and every
/// string that leaves passes `DiagnosticTokenRule` or is replaced: the
/// incident and image UUIDs are parsed as UUIDs, an image outside Pipit's
/// bundle and the system is named `other`, and any other value that fails the
/// rule becomes `invalid`. `asi`, `lastExceptionBacktrace`, exception
/// messages and subtypes, symbol names, thread names and queues, register
/// state, VM regions, `procPath`, the parent process, and `crashReporterKey`
/// are never read into the result.
public enum CrashReportReducer {
    /// ReportCrash's log type for a crash.
    public static let crashBugType = "309"
    /// A crash report runs to a few hundred kilobytes. A file far larger is
    /// not one, and is not read into memory.
    public static let maximumReportBytes = 8 * 1024 * 1024

    private static let unknown = "unknown"

    public static func reduce(_ data: Data) -> CrashRecord? {
        guard data.count <= maximumReportBytes,
            let newline = data.firstIndex(of: UInt8(ascii: "\n")),
            let header = JSONValue.parse(data[data.startIndex..<newline]),
            isCrash(header),
            let body = JSONValue.parse(data[data.index(after: newline)...]),
            !isNonFatal(body)
        else { return nil }

        let identifier =
            nonEmpty(header["bundleID"]?.stringValue)
            ?? nonEmpty(body["bundleInfo"]?["CFBundleIdentifier"]?.stringValue)
        let name =
            nonEmpty(header["app_name"]?.stringValue) ?? nonEmpty(header["name"]?.stringValue)
            ?? nonEmpty(body["procName"]?.stringValue)
        guard let process = PipitProcess.matching(name: name, identifier: identifier),
            let pid = body["pid"]?.integerValue.flatMap({ Int32(exactly: $0) }),
            let incident = uuid(header["incident_id"]) ?? uuid(body["incident"]),
            let occurredAt = (body["captureTime"] ?? header["timestamp"])?.stringValue.flatMap(reportTime)
        else { return nil }

        let images = ImageScope(
            executable: nonEmpty(body["procPath"]?.stringValue), process: process,
            images: body["usedImages"]?.arrayValue ?? []
        )
        let thread = faultingThread(body)
        let (frames, referenced) = images.reduce(frames: thread.flatMap { body["threads"]?.arrayValue?[$0] })
        let system = osVersion(header: header, body: body)

        let summary = CrashSummary(
            incident: incident, kind: .crash, process: process, occurredAt: occurredAt,
            app: app(header: header, body: body),
            os: system.version, osBuild: system.build,
            exceptionType: body["exception"]?["type"]?.stringValue.map(DiagnosticTokenRule.token),
            signal: body["exception"]?["signal"]?.stringValue.map(DiagnosticTokenRule.token),
            termination: termination(body["termination"]),
            faultingThread: thread, frames: frames, images: referenced
        )
        return CrashRecord(
            pid: pid,
            launchedAt: body["procLaunch"]?.stringValue.flatMap(reportTime),
            binaryUUID: images.executableUUID ?? uuid(header["slice_uuid"]),
            summary: summary
        )
    }

    /// Reads the file at `url`, or nil when it cannot be read or reduced.
    public static func reduce(contentsOf url: URL) -> CrashRecord? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumReportBytes,
            let data = try? Data(contentsOf: url)
        else { return nil }
        return reduce(data)
    }

    // MARK: fields

    private static func isCrash(_ header: JSONValue) -> Bool {
        switch header["bug_type"] {
        case .string(let type): type == crashBugType
        case .integer(let type): String(type) == crashBugType
        default: false
        }
    }

    /// A report the process survived, or one written without a crash, would
    /// otherwise turn a clean exit into a crash.
    private static func isNonFatal(_ body: JSONValue) -> Bool {
        body["isNonFatal"]?.boolValue == true || body["isSimulated"]?.boolValue == true
    }

    private static func app(header: JSONValue, body: JSONValue) -> CrashSummary.App {
        let bundle = body["bundleInfo"]
        let version =
            nonEmpty(bundle?["CFBundleShortVersionString"]?.stringValue)
            ?? nonEmpty(header["app_version"]?.stringValue)
        let build =
            nonEmpty(bundle?["CFBundleVersion"]?.stringValue) ?? nonEmpty(header["build_version"]?.stringValue)
        return CrashSummary.App(
            version: version.map(DiagnosticTokenRule.token) ?? unknown,
            build: build.flatMap { Int($0) }.flatMap { $0 >= 0 ? $0 : nil } ?? 0
        )
    }

    /// `osVersion.train` is `macOS 15.6.1` and `osVersion.build` is `24G90`.
    /// A report without them still has the header's `macOS 15.6.1 (24G90)`.
    private static func osVersion(header: JSONValue, body: JSONValue) -> (version: String, build: String) {
        var version = body["osVersion"]?["train"]?.stringValue
        var build = body["osVersion"]?["build"]?.stringValue
        if version == nil || build == nil, let line = header["os_version"]?.stringValue {
            let parts = line.split(separator: " ")
            if version == nil { version = parts.first { $0.first?.isNumber == true }.map(String.init) }
            if build == nil, let last = parts.last, last.hasPrefix("("), last.hasSuffix(")") {
                build = String(last.dropFirst().dropLast())
            }
        }
        let trimmed = version.map { $0.hasPrefix("macOS ") ? String($0.dropFirst(6)) : $0 }
        return (
            nonEmpty(trimmed).map(DiagnosticTokenRule.token) ?? unknown,
            nonEmpty(build).map(DiagnosticTokenRule.token) ?? unknown
        )
    }

    private static func termination(_ termination: JSONValue?) -> String? {
        guard let namespace = nonEmpty(termination?["namespace"]?.stringValue) else { return nil }
        guard let code = termination?["code"]?.integerValue else { return DiagnosticTokenRule.token(namespace) }
        return DiagnosticTokenRule.token("\(namespace).\(code)")
    }

    /// `faultingThread`, or the thread marked `triggered` in a report that
    /// left the index out.
    private static func faultingThread(_ body: JSONValue) -> Int? {
        let threads = body["threads"]?.arrayValue ?? []
        if let index = body["faultingThread"]?.integerValue.flatMap({ Int(exactly: $0) }),
            threads.indices.contains(index)
        {
            return index
        }
        return threads.firstIndex { $0["triggered"]?.boolValue == true }
    }

    private static func uuid(_ value: JSONValue?) -> String? {
        value?.stringValue.flatMap { UUID(uuidString: $0) }?.uuidString.lowercased()
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    // MARK: time

    /// ReportCrash writes local time with an offset and a varying number of
    /// fractional digits: `2026-10-21 03:18:16.4321 -0700`.
    static func reportTime(_ text: String) -> Date? {
        let parts = text.split(separator: " ")
        guard parts.count == 3 else { return nil }
        let day = parts[0].split(separator: "-").compactMap { Int($0) }
        let clock = parts[1].split(separator: ":", omittingEmptySubsequences: false)
        let zone = parts[2]
        guard day.count == 3, clock.count == 3, zone.count == 5,
            let sign = zone.first, sign == "+" || sign == "-",
            let zoneHours = Int(zone.dropFirst().prefix(2)), let zoneMinutes = Int(zone.suffix(2)),
            let hour = Int(clock[0]), let minute = Int(clock[1])
        else { return nil }
        let secondParts = clock[2].split(separator: ".", omittingEmptySubsequences: false)
        guard let second = Int(secondParts[0]), secondParts.count <= 2 else { return nil }
        var fraction = 0.0
        if secondParts.count == 2 {
            guard let digits = Double("0." + secondParts[1]), secondParts[1].allSatisfy(\.isNumber) else {
                return nil
            }
            fraction = digits
        }
        guard (1...12).contains(day[1]), (1...31).contains(day[2]), (0...23).contains(hour),
            (0...59).contains(minute), (0...60).contains(second), zoneHours <= 23, zoneMinutes <= 59
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = DateComponents(
            year: day[0], month: day[1], day: day[2], hour: hour, minute: minute, second: second
        )
        guard let utc = calendar.date(from: components) else { return nil }
        let offset = TimeInterval((zoneHours * 60 + zoneMinutes) * 60) * (sign == "-" ? -1 : 1)
        return utc.addingTimeInterval(fraction - offset)
    }
}

/// Which of a report's images belong to Pipit or the system, and the frames
/// of the faulting thread rewritten against the images they name.
private struct ImageScope {
    let executable: String?
    let process: PipitProcess
    let images: [JSONValue]
    /// `/…/Pipit.app/` when the process ran from a bundle. Every executable
    /// Pipit ships lives in the app's bundle, the Safari extension one level
    /// further down in `Contents/PlugIns`, so the outermost `.app` is the one.
    let bundleRoot: String?

    init(executable: String?, process: PipitProcess, images: [JSONValue]) {
        self.executable = executable
        self.process = process
        self.images = images
        bundleRoot = executable.flatMap { path in
            path.range(of: ".app/Contents/").map { String(path[..<$0.lowerBound]) + ".app/" }
        }
    }

    /// The UUID of the image the process was started from.
    var executableUUID: String? {
        guard let executable else { return nil }
        return images.first { $0["path"]?.stringValue == executable }.flatMap(Self.uuid)
    }

    /// The faulting thread's frames, at most `CrashSummary.maximumFrames`, and
    /// the images they name, in the report's order. A frame whose image index
    /// or offset is missing or out of range is dropped, since nothing can
    /// symbolicate it.
    func reduce(frames thread: JSONValue?) -> ([CrashSummary.Frame], [CrashSummary.Image]) {
        let raw = (thread?["frames"]?.arrayValue ?? []).prefix(CrashSummary.maximumFrames)
        let located: [(image: Int, offset: Int)] = raw.compactMap { frame in
            guard let image = frame["imageIndex"]?.integerValue.flatMap({ Int(exactly: $0) }),
                images.indices.contains(image),
                let offset = frame["imageOffset"]?.integerValue.flatMap({ Int(exactly: $0) }), offset >= 0
            else { return nil }
            return (image, offset)
        }
        let used = Set(located.map(\.image)).sorted()
        let position = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($1, $0) })
        let frames = located.compactMap { frame in
            position[frame.image].map { CrashSummary.Frame(image: $0, offset: frame.offset) }
        }
        return (frames, used.map { image(images[$0]) })
    }

    private func image(_ image: JSONValue) -> CrashSummary.Image {
        let path = image["path"]?.stringValue
        let arch = image["arch"]?.stringValue.map(DiagnosticTokenRule.token) ?? "unknown"
        let base = image["base"]?.integerValue.flatMap { Int(exactly: $0) }.flatMap { $0 >= 0 ? $0 : nil } ?? 0
        guard isNamed(path: path, name: image["name"]?.stringValue) else {
            return CrashSummary.Image(name: CrashSummary.otherImage, uuid: nil, arch: arch, base: base)
        }
        let name = image["name"]?.stringValue ?? path.map { URL(fileURLWithPath: $0).lastPathComponent }
        return CrashSummary.Image(
            name: name.map(DiagnosticTokenRule.token) ?? DiagnosticTokenRule.invalid,
            uuid: Self.uuid(image), arch: arch, base: base
        )
    }

    /// Pipit's own images and the system's keep their names. A report with no
    /// executable path still names Pipit's executable, matched by its name.
    private func isNamed(path: String?, name: String?) -> Bool {
        guard let path else { return executable == nil && name == process.executableName }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/lib/") { return true }
        if path == executable { return true }
        if let bundleRoot, path.hasPrefix(bundleRoot) { return true }
        return false
    }

    private static func uuid(_ image: JSONValue) -> String? {
        image["uuid"]?.stringValue.flatMap { UUID(uuidString: $0) }?.uuidString.lowercased()
    }
}
