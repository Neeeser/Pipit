import Foundation

/// An agent that reads skills from a folder in the home directory.
public enum SkillTarget: String, CaseIterable, Identifiable, Sendable {
    /// Claude Code, in `~/.claude/skills`.
    case claude
    /// The shared `~/.agents/skills` folder that Codex, Gemini CLI and others read.
    case agents

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claude: "Claude Code"
        case .agents: "Codex and other agents"
        }
    }

    public func skillsDirectory(home: URL) -> URL {
        switch self {
        case .claude: home.appendingPathComponent(".claude/skills", isDirectory: true)
        case .agents: home.appendingPathComponent(".agents/skills", isDirectory: true)
        }
    }

    /// Whether the agent has been used on this Mac, judged by its own folder.
    public func isPresent(home: URL) -> Bool {
        let folders: [String] =
            switch self {
            case .claude: [".claude"]
            case .agents: [".agents", ".codex"]
            }
        return folders.contains {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: home.appendingPathComponent($0).path, isDirectory: &isDirectory
            ) && isDirectory.boolValue
        }
    }
}

/// How an installed piece compares with the copy that ships in the app.
public enum IntegrationState: Equatable, Sendable {
    case notInstalled
    case installed
    /// Installed, but not the copy in this app: an older skill, or a command
    /// link into an app that has since moved.
    case updateAvailable
}

/// Puts `pipit` on the command path and the skill where agents look for it, and
/// takes them off again.
///
/// The command line tool and the Settings page both run through this, so there
/// is one install path. Everything it writes is something the person asked for,
/// and it removes only what it can tell it made: a link to a `pipit-cli`, and a
/// skill folder whose `SKILL.md` is named `pipit`.
public struct AgentInstaller: Sendable {
    public static let skillName = "pipit"
    public static let commandName = "pipit"

    public var home: URL
    /// The `pipit-cli` file the command link points at.
    public var commandLine: URL
    /// The folder holding the `SKILL.md` that ships in the app.
    public var skillSource: URL
    public var pathVariable: String

    public init(home: URL, commandLine: URL, skillSource: URL, pathVariable: String) {
        self.home = home
        self.commandLine = commandLine
        self.skillSource = skillSource
        self.pathVariable = pathVariable
    }

    /// The installer for an application bundle, whose `Contents` folder holds
    /// both the tool and the skill.
    public static func bundled(in contents: URL, home: URL, pathVariable: String) -> AgentInstaller {
        AgentInstaller(
            home: home,
            commandLine: contents.appendingPathComponent("MacOS/pipit-cli"),
            skillSource: contents.appendingPathComponent("Resources/skills/\(skillName)", isDirectory: true),
            pathVariable: pathVariable
        )
    }

    public var commandLink: URL {
        home.appendingPathComponent(".local/bin/\(Self.commandName)")
    }

    public func skillFolder(for target: SkillTarget) -> URL {
        target.skillsDirectory(home: home).appendingPathComponent(Self.skillName, isDirectory: true)
    }

    /// Whether this copy of the app carries the tool. A build run from the
    /// package directory does not.
    public var canInstallCommand: Bool { FileManager.default.fileExists(atPath: commandLine.path) }

    public var canInstallSkill: Bool {
        FileManager.default.fileExists(atPath: skillSource.appendingPathComponent("SKILL.md").path)
    }

    /// The agents to show: those with a folder on this Mac, and any that already
    /// hold the skill.
    public func listedTargets() -> [SkillTarget] {
        SkillTarget.allCases.filter {
            $0.isPresent(home: home) || skillState($0) != .notInstalled
        }
    }

    // MARK: state

    public func commandState() -> IntegrationState {
        guard let destination = linkedPipitCLI() else { return .notInstalled }
        let current = destination.standardizedFileURL.path == commandLine.standardizedFileURL.path
        return current && canInstallCommand ? .installed : .updateAvailable
    }

    public func skillState(_ target: SkillTarget) -> IntegrationState {
        let folder = skillFolder(for: target)
        guard holdsThisSkill(folder) else { return .notInstalled }
        return Self.sameContents(skillSource, folder) ? .installed : .updateAvailable
    }

    // MARK: command

    @discardableResult
    public func installCommand() throws -> [String] {
        let link = commandLink
        let directory = link.deletingLastPathComponent()
        let path = commandLine.path
        // A disk image, an external volume or a quarantined copy is ejected or
        // moved, and a link into it would point at nothing afterwards.
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            throw CLIError.linkBlocked(
                path: link.path,
                reason: "Pipit is running from a disk image or an external volume. Move it to Applications first."
            )
        }
        let fileManager = FileManager.default
        if let existing = try? fileManager.destinationOfSymbolicLink(atPath: link.path) {
            guard URL(fileURLWithPath: existing).lastPathComponent == commandLine.lastPathComponent else {
                throw CLIError.linkBlocked(path: link.path, reason: "it is a link to \(existing), not to Pipit.")
            }
        } else if fileManager.fileExists(atPath: link.path) {
            throw CLIError.linkBlocked(path: link.path, reason: "a file is already there.")
        }
        // The new link is made beside the old one and renamed over it, so a
        // failure leaves the old link where it was.
        let staged = directory.appendingPathComponent(".\(Self.commandName)-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(at: staged, withDestinationURL: commandLine)
            guard rename(staged.path, link.path) == 0 else {
                throw CocoaError(
                    .fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
            }
        } catch {
            try? fileManager.removeItem(at: staged)
            throw CLIError.installFailed(path: link.path, reason: error.localizedDescription)
        }
        var lines = ["Linked \(link.path) to \(path)."]
        let onPath = pathVariable.split(separator: ":").contains { String($0) == directory.path }
        if !onPath { lines.append("\(directory.path) is not on PATH. Add it to your shell profile.") }
        return lines
    }

    @discardableResult
    public func removeCommand() throws -> [String] {
        guard linkedPipitCLI() != nil else {
            if FileManager.default.fileExists(atPath: commandLink.path) {
                throw CLIError.linkBlocked(path: commandLink.path, reason: "it is not a link Pipit made.")
            }
            return []
        }
        try remove(commandLink)
        return ["Removed \(commandLink.path)."]
    }

    /// Where the `pipit` link points, when it is a link to a `pipit-cli`.
    private func linkedPipitCLI() -> URL? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: commandLink.path),
            URL(fileURLWithPath: destination).lastPathComponent == commandLine.lastPathComponent
        else { return nil }
        return URL(fileURLWithPath: destination)
    }

    // MARK: skill

    @discardableResult
    public func installSkill(_ target: SkillTarget) throws -> [String] {
        guard canInstallSkill else { throw CLIError.skillSourceMissing(path: skillSource.path) }
        let destination = skillFolder(for: target)
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        if fileManager.fileExists(atPath: destination.path), !holdsThisSkill(destination) {
            throw CLIError.installFailed(
                path: destination.path, reason: "a different skill is already there."
            )
        }
        let staged = parent.appendingPathComponent(".\(Self.skillName)-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            try fileManager.copyItem(at: skillSource, to: staged)
            if (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) != nil {
                // A skill installer's link to its own copy. Only the link is
                // replaced, and replaceItemAt cannot do that for a folder link.
                try fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: staged, to: destination)
            } else if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staged)
            throw CLIError.installFailed(path: destination.path, reason: error.localizedDescription)
        }
        return ["Installed the skill in \(destination.path)."]
    }

    @discardableResult
    public func removeSkill(_ target: SkillTarget) throws -> [String] {
        let folder = skillFolder(for: target)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        guard holdsThisSkill(folder) else {
            throw CLIError.installFailed(path: folder.path, reason: "a different skill is there.")
        }
        try remove(folder)
        return ["Removed \(folder.path)."]
    }

    /// A folder is this skill when its `SKILL.md` names it, which is what lets
    /// an update replace the old copy without ever touching someone's own skill
    /// that happens to share the folder name.
    private func holdsThisSkill(_ directory: URL) -> Bool {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("SKILL.md"), encoding: .utf8)
        else { return false }
        return text.split(separator: "\n").prefix(10).contains { $0 == "name: \(Self.skillName)" }
    }

    /// Whether `installed` holds exactly the files `source` does.
    private static func sameContents(_ source: URL, _ installed: URL) -> Bool {
        func files(_ root: URL) -> [String: Data]? {
            let fileManager = FileManager.default
            guard let names = fileManager.enumerator(atPath: root.path) else { return nil }
            var result: [String: Data] = [:]
            for case let name as String in names where (name as NSString).lastPathComponent != ".DS_Store" {
                let url = root.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                    let data = try? Data(contentsOf: url)
                else { continue }
                result[name] = data
            }
            return result
        }
        guard let expected = files(source), let found = files(installed) else { return false }
        return expected == found
    }

    private func remove(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw CLIError.installFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    // MARK: command line

    func run(_ options: Invocation.InstallOptions) throws -> [String] {
        var report: [String] = []
        if options.linkCommand { report += try installCommand() }
        if options.installSkill {
            let targets =
                options.agents.isEmpty ? SkillTarget.allCases.filter { $0.isPresent(home: home) } : options.agents
            guard !targets.isEmpty else { throw CLIError.noAgentFound }
            for target in targets { report += try installSkill(target) }
        }
        return report
    }

    func runRemoval(_ options: Invocation.InstallOptions) throws -> [String] {
        var report: [String] = []
        if options.linkCommand { report += try removeCommand() }
        if options.installSkill {
            // With no agent named, a folder that is someone else's skill is not
            // Pipit's to remove, so it is passed over instead of stopping the run.
            let targets =
                options.agents.isEmpty
                ? SkillTarget.allCases.filter { skillState($0) != .notInstalled } : options.agents
            for target in targets { report += try removeSkill(target) }
        }
        return report
    }
}
