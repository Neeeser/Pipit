import Foundation

/// What the command line asked for, read once so the commands never see a raw
/// argument.
public struct Invocation: Equatable, Sendable {
    public enum Command: Equatable, Sendable {
        case help
        case version
        case root
        case list(ListOptions)
        case show(id: String)
        case install(InstallOptions)
        case uninstall(InstallOptions)
        case crashes
    }

    public struct ListOptions: Equatable, Sendable {
        public var limit: Int?
        public var since: Date?
        public var folder: String?
        public var title: String?
        public var includeArchived = false
    }

    public struct InstallOptions: Equatable, Sendable {
        /// Empty means every agent whose folder exists in the home directory.
        public var agents: [SkillTarget] = []
        public var linkCommand = true
        public var installSkill = true
    }

    public var command: Command
    public var root: URL?
    public var json: Bool
}

extension Invocation {
    private static let switches: Set<String> = [
        "--json", "--archived", "--skip-link", "--skip-skill", "--help", "--version",
    ]
    private static let valued: Set<String> = [
        "--root", "--limit", "--since", "--folder", "--title", "--agent",
    ]

    /// Flags each command accepts. A flag outside its command is refused
    /// instead of ignored, because a dropped `--limit` or `--since` would hand
    /// back a longer list than the caller asked for and look like an answer.
    private static func accepted(by command: Command) -> Set<String> {
        switch command {
        case .help, .version: []
        case .root: ["--root", "--json"]
        case .list: ["--root", "--json", "--limit", "--since", "--folder", "--title", "--archived"]
        case .show: ["--root", "--json"]
        case .install, .uninstall: ["--agent", "--skip-link", "--skip-skill"]
        // The crash reports and the launch record live in the user's Logs
        // folder whichever meetings folder is chosen, so --root has no meaning.
        case .crashes: ["--json"]
        }
    }

    public static func parse(_ arguments: [String], calendar: Calendar = .current) throws -> Invocation {
        var positionals: [String] = []
        var flags: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "-h" {
                flags["--help"] = ""
            } else if switches.contains(argument) {
                flags[argument] = ""
            } else if valued.contains(argument) {
                guard index < arguments.count else {
                    throw CLIError.usage("\(argument) needs a value.")
                }
                // `--agent` repeats; the others keep the last value.
                if argument == "--agent", let earlier = flags[argument] {
                    flags[argument] = earlier + "," + arguments[index]
                } else {
                    flags[argument] = arguments[index]
                }
                index += 1
            } else if argument.hasPrefix("-") {
                throw CLIError.usage("Unknown option \(argument).")
            } else {
                positionals.append(argument)
            }
        }

        if flags["--help"] != nil || positionals.isEmpty && flags["--version"] == nil {
            return Invocation(command: .help, root: nil, json: false)
        }
        if flags["--version"] != nil {
            return Invocation(command: .version, root: nil, json: false)
        }

        let command = try command(for: positionals, flags: flags, calendar: calendar)
        let allowed = accepted(by: command)
        if let stray = flags.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw CLIError.usage("\(stray) does not apply to `\(positionals.joined(separator: " "))`.")
        }
        return Invocation(
            command: command,
            root: flags["--root"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            json: flags["--json"] != nil
        )
    }

    private static func command(
        for positionals: [String], flags: [String: String], calendar: Calendar
    ) throws -> Command {
        switch positionals {
        case ["root"]:
            return .root
        case ["meetings", "list"]:
            return .list(try listOptions(flags, calendar: calendar))
        case ["install"]:
            return .install(try installOptions(flags))
        case ["uninstall"]:
            return .uninstall(try installOptions(flags))
        case ["diagnostics", "crashes"]:
            return .crashes
        default:
            if positionals.count == 3, positionals[0] == "meetings", positionals[1] == "show" {
                return .show(id: positionals[2])
            }
            if positionals.count == 2, positionals[0] == "meetings", positionals[1] == "show" {
                throw CLIError.usage("`meetings show` needs a meeting identifier.")
            }
            throw CLIError.usage("Unknown command `\(positionals.joined(separator: " "))`.")
        }
    }

    private static func listOptions(_ flags: [String: String], calendar: Calendar) throws -> ListOptions {
        var options = ListOptions()
        if let text = flags["--limit"] {
            guard let limit = Int(text), limit > 0 else {
                throw CLIError.usage("--limit takes a whole number above zero.")
            }
            options.limit = limit
        }
        if let text = flags["--since"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            guard let day = formatter.date(from: text) else {
                throw CLIError.usage("--since takes a date written YYYY-MM-DD.")
            }
            options.since = day
        }
        options.folder = flags["--folder"]
        options.title = flags["--title"]
        options.includeArchived = flags["--archived"] != nil
        return options
    }

    private static func installOptions(_ flags: [String: String]) throws -> InstallOptions {
        var options = InstallOptions()
        for name in (flags["--agent"] ?? "").split(separator: ",") {
            guard let target = SkillTarget(rawValue: String(name)) else {
                throw CLIError.usage("--agent takes claude or agents, not \(name).")
            }
            if !options.agents.contains(target) { options.agents.append(target) }
        }
        options.linkCommand = flags["--skip-link"] == nil
        options.installSkill = flags["--skip-skill"] == nil
        return options
    }
}
