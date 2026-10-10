import Foundation
@testable import PipitCLIKit
import PipitCore
import Testing

/// The `pipit` command, run against scratch archives with invented meetings.
@Suite("Command line")
struct CommandLineTests {
    /// A scratch home directory holding an archive, in the layout the app writes.
    private struct Machine {
        let home: URL
        let root: URL
        let repository: MeetingRepository

        init() throws {
            home = try TestPaths.makeTemporaryDirectory()
            root = home.appendingPathComponent("Meetings", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            repository = MeetingRepository(root: root)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: home) }

        var support: URL { home.appendingPathComponent("Support", isDirectory: true) }

        /// Where a bundled `pipit-cli` would sit. Under the scratch home, so a
        /// Pipit installed on the machine running the suite cannot answer.
        var executable: URL { home.appendingPathComponent("Pipit.app/Contents/MacOS/pipit-cli") }

        func environment() -> CLIEnvironment {
            CLIEnvironment(
                home: home, supportDirectory: support, executable: executable, pathVariable: "/usr/bin"
            )
        }

        func run(_ arguments: String...) -> CommandResult {
            run(arguments)
        }

        func run(_ arguments: [String]) -> CommandResult {
            PipitCommandLine.run(arguments, environment: environment())
        }

        @discardableResult
        func meeting(
            _ title: String, day: Int, folder: String? = nil, archived: Bool = false,
            files: [String] = []
        ) throws -> MeetingMetadata {
            let started = MeetingFolderNameTests.date(year: 2026, month: 9, day: day, hour: 10, minute: 0)
            let created = try repository.createMeeting(
                source: .genericCall, provider: .unknown, startedAt: started,
                titles: TitleCandidates(provider: title, timestampFallback: "fallback"), now: started
            )
            _ = try created.store.updateMetadata {
                $0.processing = ProcessingStatus(state: .complete)
                if archived { $0.archivedAt = started }
            }
            for name in files {
                try "synthetic \(name)".write(
                    to: created.store.layout.root.appendingPathComponent(name), atomically: true, encoding: .utf8
                )
            }
            if let folder {
                _ = try MeetingFolderStore(root: root).create(name: folder, about: "")
                try repository.move(meetingID: created.metadata.id, toFolder: folder)
            }
            return created.metadata
        }

        /// Writes the Settings file the app keeps, naming `root` as the archive.
        func chooseRoot(_ path: String) throws {
            var settings = AppSettings()
            settings.storageRootPath = path
            try SettingsStore(directory: support).save(settings)
        }
    }

    private func decode<Report: Decodable>(_ type: Report.Type, from result: CommandResult) throws -> Report {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(result.standardOutput.utf8))
    }

    // MARK: reading

    @Test("the list is newest first and carries the schema version")
    func theListIsNewestFirstAndCarriesTheSchemaVersion() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        try machine.meeting("Budget review", day: 3)
        try machine.meeting("Roadmap sync", day: 17)
        try machine.meeting("Design critique", day: 9)

        let result = machine.run("meetings", "list", "--json", "--root", machine.root.path)
        #expect(result.exitCode == 0)
        let listing = try decode(MeetingListing.self, from: result)
        #expect(listing.schemaVersion == 1)
        #expect(listing.root == machine.root.path)
        #expect(listing.meetings.map(\.title) == ["Roadmap sync", "Design critique", "Budget review"])
    }

    @Test("a list can be narrowed by title, folder, date and count")
    func aListCanBeNarrowedByTitleFolderDateAndCount() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        try machine.meeting("Budget review", day: 3, folder: "Finance")
        try machine.meeting("Budget planning", day: 17)
        try machine.meeting("Design critique", day: 9)

        func titles(_ extra: String...) throws -> [String] {
            let result = machine.run(["meetings", "list", "--json", "--root", machine.root.path] + extra)
            return try decode(MeetingListing.self, from: result).meetings.map(\.title)
        }
        #expect(try titles("--title", "BUDGET") == ["Budget planning", "Budget review"])
        #expect(try titles("--folder", "finance") == ["Budget review"])
        #expect(try titles("--since", "2026-09-08") == ["Budget planning", "Design critique"])
        #expect(try titles("--limit", "1") == ["Budget planning"])
    }

    @Test("an archived meeting is left out unless asked for")
    func anArchivedMeetingIsLeftOutUnlessAskedFor() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        try machine.meeting("Kept", day: 3)
        try machine.meeting("Put away", day: 4, archived: true)

        let shown = machine.run("meetings", "list", "--root", machine.root.path).standardOutput
        #expect(shown.contains("Kept"))
        #expect(!shown.contains("Put away"))
        let all = machine.run("meetings", "list", "--archived", "--root", machine.root.path).standardOutput
        #expect(all.contains("Put away"))
    }

    @Test("show names the files a meeting holds and leaves out the ones it lacks")
    func showNamesTheFilesAMeetingHoldsAndLeavesOutTheOnesItLacks() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        let kept = try machine.meeting("Budget review", day: 3, files: ["transcript.md", "summary.md"])

        // A prefix of the identifier is enough while it names one meeting.
        let result = machine.run("meetings", "show", String(kept.id.prefix(15)), "--json", "--root", machine.root.path)
        #expect(result.exitCode == 0)
        let detail = try decode(MeetingDetail.self, from: result)
        #expect(detail.meeting.id == kept.id)
        let files = try #require(detail.recordings.first)
        #expect(files.transcript?.hasSuffix("transcript.md") == true)
        #expect(files.summary?.hasSuffix("summary.md") == true)
        #expect(files.notes == nil)
        #expect(files.recording == nil)
    }

    @Test("show refuses an identifier that matches nothing or several meetings")
    func showRefusesAnIdentifierThatMatchesNothingOrSeveralMeetings() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        try machine.meeting("Budget review", day: 3)
        try machine.meeting("Budget planning", day: 3)

        let missing = machine.run("meetings", "show", "2031", "--root", machine.root.path)
        #expect(missing.exitCode == 1)
        #expect(missing.standardError.contains("No meeting matches 2031"))
        let ambiguous = machine.run("meetings", "show", "2026-09-03", "--root", machine.root.path)
        #expect(ambiguous.exitCode == 1)
        #expect(ambiguous.standardError.contains("matches 2 meetings"))
    }

    @Test("the meetings folder comes from Settings unless --root names another")
    func theMeetingsFolderComesFromSettingsUnlessRootNamesAnother() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        try machine.chooseRoot(machine.root.path)

        #expect(machine.run("root").standardOutput == machine.root.path + "\n")
        #expect(machine.run("root", "--root", "/tmp").standardOutput == "/tmp\n")

        try machine.chooseRoot(machine.home.appendingPathComponent("Gone").path)
        let missing = machine.run("root")
        #expect(missing.exitCode == 1)
        #expect(missing.standardError.contains("No meetings folder at"))
    }

    // MARK: arguments

    @Test("an option that is unknown, misplaced or missing its value is refused")
    func anOptionThatIsUnknownMisplacedOrMissingItsValueIsRefused() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        // A dropped --limit would answer with the whole archive.
        for arguments in [
            ["root", "--limit", "3"], ["meetings", "list", "--bogus"], ["meetings", "list", "--limit"],
            ["meetings", "list", "--limit", "0"], ["meetings", "list", "--since", "yesterday"],
            ["meetings", "show"], ["nothing"],
        ] {
            let result = PipitCommandLine.run(arguments, environment: machine.environment())
            #expect(result.exitCode == 2, "\(arguments)")
            #expect(result.standardOutput.isEmpty)
        }
        #expect(machine.run("--help").standardOutput.contains("pipit meetings list"))
        #expect(machine.run("--version").standardOutput == "pipit development build\n")

        let plist = machine.executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        try FileManager.default.createDirectory(
            at: plist.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "9.8.7"], format: .xml, options: 0
        ).write(to: plist)
        #expect(machine.run("--version").standardOutput == "pipit 9.8.7\n")
    }

    // MARK: install

    private func bundledSkill(in machine: Machine, text: String = "name: pipit\n") throws -> URL {
        let source = machine.home.appendingPathComponent("skill-source/pipit", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\n\(text)---\nbody".write(
            to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        return source
    }

    private func installer(_ machine: Machine, executable: String, source: URL) -> AgentInstaller {
        AgentInstaller(
            home: machine.home, commandLine: URL(fileURLWithPath: executable),
            skillSource: source, pathVariable: "/usr/bin"
        )
    }

    @Test("install links the command and copies the skill to each agent folder that exists")
    func installLinksTheCommandAndCopiesTheSkillToEachAgentFolderThatExists() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        let source = try bundledSkill(in: machine)
        try FileManager.default.createDirectory(
            at: machine.home.appendingPathComponent(".claude"), withIntermediateDirectories: true
        )
        let tool = machine.home.appendingPathComponent("Pipit.app/Contents/MacOS/pipit-cli")
        try FileManager.default.createDirectory(
            at: tool.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "binary".write(to: tool, atomically: true, encoding: .utf8)

        let lines = try installer(machine, executable: tool.path, source: source).run(.init())
        let link = machine.home.appendingPathComponent(".local/bin/pipit")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == tool.path)
        #expect(lines.contains { $0.contains("is not on PATH") })
        let installed = machine.home.appendingPathComponent(".claude/skills/pipit/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: installed.path))
        // Codex has no folder on this machine, so it is not given one.
        #expect(!FileManager.default.fileExists(atPath: machine.home.appendingPathComponent(".agents").path))

        // Running it again after an update replaces the copy and keeps the link.
        try "---\nname: pipit\n---\nnewer".write(
            to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        _ = try installer(machine, executable: tool.path, source: source).run(.init())
        #expect(try String(contentsOf: installed, encoding: .utf8).hasSuffix("newer"))
    }

    @Test("install does not replace a skill, a file or a link that is not Pipit's")
    func installDoesNotReplaceASkillAFileOrALinkThatIsNotPipits() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        let source = try bundledSkill(in: machine)
        let tool = "/Applications/Pipit.app/Contents/MacOS/pipit-cli"

        let foreignSkill = machine.home.appendingPathComponent(".claude/skills/pipit", isDirectory: true)
        try FileManager.default.createDirectory(at: foreignSkill, withIntermediateDirectories: true)
        try "---\nname: something-else\n---\n".write(
            to: foreignSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        #expect(throws: CLIError.self) {
            try installer(machine, executable: tool, source: source).run(.init(linkCommand: false))
        }
        #expect(
            try String(contentsOf: foreignSkill.appendingPathComponent("SKILL.md"), encoding: .utf8).contains(
                "something-else"))

        let binDirectory = machine.home.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let occupied = binDirectory.appendingPathComponent("pipit")
        try "mine".write(to: occupied, atomically: true, encoding: .utf8)
        #expect(throws: CLIError.self) {
            try installer(machine, executable: tool, source: source).run(.init(installSkill: false))
        }
        #expect(try String(contentsOf: occupied, encoding: .utf8) == "mine")
    }

    @Test("a skill or link is reported against the copy in the app, and removal takes only Pipit's own")
    func aSkillOrLinkIsReportedAgainstTheCopyInTheAppAndRemovalTakesOnlyPipitsOwn() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        let source = try bundledSkill(in: machine)
        let tool = machine.home.appendingPathComponent("Pipit.app/Contents/MacOS/pipit-cli")
        try FileManager.default.createDirectory(
            at: tool.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "binary".write(to: tool, atomically: true, encoding: .utf8)
        let installer = installer(machine, executable: tool.path, source: source)

        #expect(installer.skillState(.claude) == .notInstalled)
        #expect(installer.commandState() == .notInstalled)
        try installer.installSkill(.claude)
        try installer.installCommand()
        #expect(installer.skillState(.claude) == .installed)
        #expect(installer.commandState() == .installed)

        // A newer app ships a different skill, and was moved to another folder.
        try "---\nname: pipit\n---\nnewer".write(
            to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        #expect(installer.skillState(.claude) == .updateAvailable)
        let moved = AgentInstaller(
            home: machine.home, commandLine: machine.home.appendingPathComponent("Elsewhere/pipit-cli"),
            skillSource: source, pathVariable: ""
        )
        #expect(moved.commandState() == .updateAvailable)

        try installer.removeSkill(.claude)
        try installer.removeCommand()
        #expect(installer.skillState(.claude) == .notInstalled)
        #expect(installer.commandState() == .notInstalled)

        // Someone else's skill and someone else's file are left alone.
        let foreign = installer.skillFolder(for: .agents)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try "---\nname: other\n---\n".write(
            to: foreign.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        #expect(throws: CLIError.self) { try installer.removeSkill(.agents) }
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        try FileManager.default.createDirectory(
            at: installer.commandLink.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "mine".write(to: installer.commandLink, atomically: true, encoding: .utf8)
        #expect(throws: CLIError.self) { try installer.removeCommand() }
        #expect(try String(contentsOf: installer.commandLink, encoding: .utf8) == "mine")
    }

    @Test("uninstall takes the link and the skill away and install puts them back")
    func uninstallTakesTheLinkAndTheSkillAwayAndInstallPutsThemBack() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        let bundle = machine.executable.deletingLastPathComponent().deletingLastPathComponent()
        let source = bundle.appendingPathComponent("Resources/skills/pipit", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: pipit\n---\nbody".write(
            to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: machine.executable.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "binary".write(to: machine.executable, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: machine.home.appendingPathComponent(".claude"), withIntermediateDirectories: true
        )
        let link = machine.home.appendingPathComponent(".local/bin/pipit")
        let skill = machine.home.appendingPathComponent(".claude/skills/pipit")

        #expect(machine.run("install").exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: skill.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)

        let removal = machine.run("uninstall")
        #expect(removal.exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: skill.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
        // Nothing left to remove is not an error.
        #expect(machine.run("uninstall").exitCode == 0)
    }

    @Test("install refuses to link into a disk image and to guess an agent")
    func installRefusesToLinkIntoADiskImageAndToGuessAnAgent() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        let source = try bundledSkill(in: machine)

        #expect(
            throws: CLIError.linkBlocked(
                path: machine.home.appendingPathComponent(".local/bin/pipit").path,
                reason: "Pipit is running from a disk image or an external volume. Move it to Applications first."
            )
        ) {
            try installer(machine, executable: "/Volumes/Pipit/Pipit.app/Contents/MacOS/pipit-cli", source: source)
                .run(.init(installSkill: false))
        }
        #expect(throws: CLIError.noAgentFound) {
            try installer(machine, executable: "/Applications/Pipit.app/Contents/MacOS/pipit-cli", source: source)
                .run(.init(linkCommand: false))
        }
    }

    @Test("an update replaces a skill installer's link and leaves its own copy alone")
    func anUpdateReplacesASkillInstallersLinkAndLeavesItsOwnCopyAlone() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        let source = try bundledSkill(in: machine)
        let installer = installer(
            machine, executable: "/Applications/Pipit.app/Contents/MacOS/pipit-cli", source: source)

        // `npx skills add` keeps one copy and links each agent's folder to it.
        let canonical = machine.home.appendingPathComponent("canonical/pipit", isDirectory: true)
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try "---\nname: pipit\n---\nold".write(
            to: canonical.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        let folder = installer.skillFolder(for: .claude)
        try FileManager.default.createDirectory(
            at: folder.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: canonical)
        #expect(installer.skillState(.claude) == .updateAvailable)

        try installer.installSkill(.claude)
        #expect(installer.skillState(.claude) == .installed)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: folder.path)) == nil)
        #expect(try String(contentsOf: canonical.appendingPathComponent("SKILL.md"), encoding: .utf8).hasSuffix("old"))
    }

    @Test("a stray .DS_Store does not make an installed skill look out of date")
    func aStrayDSStoreDoesNotMakeAnInstalledSkillLookOutOfDate() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        let source = try bundledSkill(in: machine)
        let installer = installer(
            machine, executable: "/Applications/Pipit.app/Contents/MacOS/pipit-cli", source: source)
        try installer.installSkill(.claude)
        try "x".write(
            to: installer.skillFolder(for: .claude).appendingPathComponent(".DS_Store"), atomically: true,
            encoding: .utf8
        )
        #expect(installer.skillState(.claude) == .installed)
    }

    @Test("installing again after the app moved points the link at the new copy")
    func installingAgainAfterTheAppMovedPointsTheLinkAtTheNewCopy() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        let source = try bundledSkill(in: machine)
        let first = installer(machine, executable: "/Applications/Pipit.app/Contents/MacOS/pipit-cli", source: source)
        let second = installer(
            machine, executable: "/Users/nobody/Apps/Pipit.app/Contents/MacOS/pipit-cli", source: source)
        try first.installCommand()
        #expect(second.commandState() == .updateAvailable)
        try second.installCommand()
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: second.commandLink.path)
                == second.commandLine.path
        )
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: second.commandLink.deletingLastPathComponent().path
        )
        #expect(leftovers == ["pipit"])
    }

    @Test("uninstall passes over a folder that is someone else's skill when no agent is named")
    func uninstallPassesOverAFolderThatIsSomeoneElsesSkillWhenNoAgentIsNamed() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        let source = try bundledSkill(in: machine)
        let installer = installer(
            machine, executable: "/Applications/Pipit.app/Contents/MacOS/pipit-cli", source: source)
        try installer.installSkill(.claude)
        let foreign = installer.skillFolder(for: .agents)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try "---\nname: other\n---\n".write(
            to: foreign.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )

        _ = try installer.runRemoval(.init(linkCommand: false))
        #expect(installer.skillState(.claude) == .notInstalled)
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        // Naming the agent asks for that folder specifically, so it is refused.
        #expect(throws: CLIError.self) { try installer.runRemoval(.init(agents: [.agents], linkCommand: false)) }
    }

    @Test("--agent takes claude or agents, repeats, and refuses anything else")
    func agentTakesClaudeOrAgentsRepeatsAndRefusesAnythingElse() throws {
        #expect(
            try Invocation.parse(["install", "--agent", "claude", "--agent", "agents", "--agent", "claude"]).command
                == .install(.init(agents: [.claude, .agents]))
        )
        #expect(throws: CLIError.usage("--agent takes claude or agents, not cursor.")) {
            try Invocation.parse(["install", "--agent", "cursor"])
        }
    }
}
