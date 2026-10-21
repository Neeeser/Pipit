import Foundation
import PipitCore

/// Where the command finds the things it reads and writes. Tests build one
/// around a scratch directory; the tool builds one from the real machine.
public struct CLIEnvironment: Sendable {
    public var home: URL
    /// Holds `settings.json`, which names the meetings folder.
    public var supportDirectory: URL
    /// The real file `pipit-cli` runs from, with symlinks resolved.
    public var executable: URL
    public var pathVariable: String
    /// This boot's `kern.bootsessionuuid`, which tells a launch record from
    /// before a restart. Nil when it could not be read.
    public var bootSession: String?

    public init(
        home: URL, supportDirectory: URL, executable: URL, pathVariable: String, bootSession: String? = nil
    ) {
        self.home = home
        self.supportDirectory = supportDirectory
        self.executable = executable
        self.pathVariable = pathVariable
        self.bootSession = bootSession
    }

    public static func live() -> CLIEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .resolvingSymlinksInPath()
        return CLIEnvironment(
            home: home,
            supportDirectory: home.appendingPathComponent("Library/Application Support/Pipit", isDirectory: true),
            executable: executable,
            pathVariable: ProcessInfo.processInfo.environment["PATH"] ?? "",
            bootSession: liveBootSession()
        )
    }

    private static func liveBootSession() -> String? {
        #if canImport(Darwin)
            return ProcessIdentity.bootSessionUUID()
        #else
            return nil
        #endif
    }

    /// `Pipit.app/Contents` when the tool runs from `Contents/MacOS`, nil for a
    /// build run straight out of `.build`.
    var bundleContents: URL? {
        let directory = executable.deletingLastPathComponent()
        guard directory.lastPathComponent == "MacOS" else { return nil }
        return directory.deletingLastPathComponent()
    }

    var skillSource: URL {
        (bundleContents ?? executable.deletingLastPathComponent())
            .appendingPathComponent("Resources/skills/\(AgentInstaller.skillName)", isDirectory: true)
    }

    var version: String {
        guard let plist = bundleContents?.appendingPathComponent("Info.plist"),
            let info = NSDictionary(contentsOf: plist),
            let short = info["CFBundleShortVersionString"] as? String
        else { return "development build" }
        return short
    }
}

public struct CommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String
}

/// The `pipit` command. Pure over its environment so the suite can run it.
public enum PipitCommandLine {
    public static func run(_ arguments: [String], environment: CLIEnvironment) -> CommandResult {
        do {
            let invocation = try Invocation.parse(arguments)
            let output = try execute(invocation, environment: environment)
            return CommandResult(exitCode: 0, standardOutput: output, standardError: "")
        } catch let error as CLIError {
            return CommandResult(exitCode: error.exitCode, standardOutput: "", standardError: error.message + "\n")
        } catch {
            return CommandResult(exitCode: 1, standardOutput: "", standardError: "\(error.localizedDescription)\n")
        }
    }

    private static func execute(_ invocation: Invocation, environment: CLIEnvironment) throws -> String {
        switch invocation.command {
        case .help:
            return usage
        case .version:
            return "pipit \(environment.version)\n"
        case .root:
            let root = try archiveRoot(invocation, environment: environment)
            return try render(RootReport(root: root.path), json: invocation.json) { "\(root.path)\n" }
        case .list(let options):
            let root = try archiveRoot(invocation, environment: environment)
            let meetings = MeetingReport(root: root).list(options)
            return try render(MeetingListing(root: root.path, meetings: meetings), json: invocation.json) {
                meetings.map(TextFormat.row).joined()
            }
        case .show(let id):
            let root = try archiveRoot(invocation, environment: environment)
            let detail = try MeetingReport(root: root).detail(id: id)
            return try render(detail, json: invocation.json) { TextFormat.detail(detail) }
        case .install(let options):
            return try installer(environment).run(options).map { $0 + "\n" }.joined()
        case .uninstall(let options):
            return try installer(environment).runRemoval(options).map { $0 + "\n" }.joined()
        case .crashes:
            let listing = CrashDiagnostics(home: environment.home, bootSession: environment.bootSession).listing()
            return try render(listing, json: invocation.json) { TextFormat.crashes(listing) }
        }
    }

    private static func installer(_ environment: CLIEnvironment) -> AgentInstaller {
        AgentInstaller(
            home: environment.home, commandLine: environment.executable,
            skillSource: environment.skillSource, pathVariable: environment.pathVariable
        )
    }

    /// The meetings folder: `--root`, else the one Settings chose.
    private static func archiveRoot(_ invocation: Invocation, environment: CLIEnvironment) throws -> URL {
        let root =
            invocation.root
            ?? SettingsStore(directory: environment.supportDirectory).load().storageRoot
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw CLIError.noArchive(path: root.path) }
        return root
    }

    private static func render<Report: Encodable>(
        _ report: Report, json: Bool, text: () -> String
    ) throws -> String {
        guard json else { return text() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let text = String(bytes: try encoder.encode(report), encoding: .utf8) else {
            throw CLIError.outputNotEncodable
        }
        return text + "\n"
    }

    static let usage = """
        usage:
          pipit root                         print the meetings folder
          pipit meetings list                list meetings, newest first
                [--limit N] [--since YYYY-MM-DD] [--folder NAME] [--title TEXT] [--archived]
          pipit meetings show ID             list the files of one meeting
          pipit install                      link `pipit` into ~/.local/bin and install the agent skill
                [--agent claude|agents] [--skip-link] [--skip-skill]
          pipit uninstall                    remove the link and the skill (same options)
          pipit diagnostics crashes          list Pipit's crash reports and how its last launch ended
          pipit --version

        Every command except install and uninstall takes --json for output meant to be parsed.
        root and the meetings commands take --root PATH to read a meetings folder other than
        the one in Settings.

        """
}

/// The plain-text forms. One meeting per line in a list, so the output pipes
/// into `grep` and `cut`.
enum TextFormat {
    static func row(_ entry: MeetingEntry) -> String {
        [entry.id, day(entry.startedAt), duration(entry.durationSeconds), entry.processingState, entry.title]
            .joined(separator: "\t") + "\n"
    }

    static func detail(_ detail: MeetingDetail) -> String {
        let meeting = detail.meeting
        var lines = [
            "id: \(meeting.id)", "title: \(meeting.title)", "started: \(day(meeting.startedAt))",
            "duration: \(duration(meeting.durationSeconds))", "state: \(meeting.processingState)",
        ]
        if let folder = meeting.folder { lines.append("folder: \(folder)") }
        if !detail.participants.isEmpty {
            lines.append("participants: " + detail.participants.map(\.name).joined(separator: ", "))
        }
        for recording in detail.recordings {
            lines.append("directory: \(recording.directory)")
            for (label, path) in [
                ("transcript", recording.transcript), ("summary", recording.summary),
                ("notes", recording.notes), ("recording", recording.recording),
            ] {
                if let path { lines.append("  \(label): \(path)") }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The last launch on one line, then one crash per line, newest first.
    static func crashes(_ listing: CrashListing) -> String {
        var lines: [String] = []
        if let launch = listing.lastLaunch {
            var line = "last launch: \(day(launch.startedAt))  pid \(launch.pid)  \(launch.version)  "
            if launch.running {
                line += "running"
            } else {
                line += launch.exit?.rawValue ?? "unknown"
                if let incident = launch.incident { line += "  \(incident)" }
            }
            lines.append(line)
        } else {
            lines.append("last launch: none recorded")
        }
        for crash in listing.crashes {
            let summary = crash.summary
            lines.append(
                [
                    summary.incident, day(summary.occurredAt), crash.process.rawValue, String(crash.pid),
                    summary.exceptionType ?? "-", summary.signal ?? "-", summary.termination ?? "-",
                ].joined(separator: "\t")
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh%02dm", minutes / 60, minutes % 60)
    }
}
