import Foundation
import PipitCLIKit
@testable import PipitUI
import Testing

/// The Agents page's model, over a scratch home directory and an invented app
/// bundle.
@MainActor
@Suite("Agents settings")
struct AgentsSettingsTests {
    private struct Machine {
        let home: URL
        let installer: AgentInstaller

        init(shipsSkill: Bool = true, shipsTool: Bool = true) throws {
            home = try TestPaths.makeTemporaryDirectory()
            let contents = home.appendingPathComponent("Pipit.app/Contents", isDirectory: true)
            installer = AgentInstaller.bundled(in: contents, home: home, pathVariable: "/usr/bin")
            if shipsSkill {
                try FileManager.default.createDirectory(
                    at: installer.skillSource, withIntermediateDirectories: true
                )
                try "---\nname: pipit\n---\nbody".write(
                    to: installer.skillSource.appendingPathComponent("SKILL.md"), atomically: true,
                    encoding: .utf8
                )
            }
            if shipsTool {
                try FileManager.default.createDirectory(
                    at: installer.commandLine.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try "binary".write(to: installer.commandLine, atomically: true, encoding: .utf8)
            }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: home) }

        func addAgentFolder(_ name: String) throws {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(name), withIntermediateDirectories: true
            )
        }
    }

    @Test("only the agents on this Mac are listed, and each row says what is installed")
    func onlyTheAgentsOnThisMacAreListedAndEachRowSaysWhatIsInstalled() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        try machine.addAgentFolder(".claude")
        let model = AgentsModel(installer: machine.installer)

        model.refresh()
        #expect(model.skills.map(\.target) == [.claude])
        #expect(model.skills.first?.state == .notInstalled)
        #expect(model.skills.first?.path == "~/.claude/skills/pipit")
        #expect(model.commandState == .notInstalled)

        model.installSkill(.claude)
        model.installCommand()
        #expect(model.failure == nil)
        #expect(model.skills.first?.state == .installed)
        #expect(model.commandState == .installed)

        model.removeSkill(.claude)
        model.removeCommand()
        #expect(model.skills.first?.state == .notInstalled)
        #expect(model.commandState == .notInstalled)
    }

    @Test("an agent that already holds the skill is listed even without its folder being detected")
    func anAgentThatAlreadyHoldsTheSkillIsListedEvenWithoutItsFolderBeingDetected() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        let model = AgentsModel(installer: machine.installer)
        model.refresh()
        #expect(model.skills.isEmpty)

        try machine.installer.installSkill(.agents)
        model.refresh()
        #expect(model.skills.map(\.target) == [.agents])
    }

    @Test("a failed install is reported and leaves the other skill where it was")
    func aFailedInstallIsReportedAndLeavesTheOtherSkillWhereItWas() throws {
        let machine = try Machine()
        defer { machine.cleanUp() }
        try machine.addAgentFolder(".claude")
        let foreign = machine.installer.skillFolder(for: .claude)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try "---\nname: mine\n---\n".write(
            to: foreign.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        let model = AgentsModel(installer: machine.installer)

        model.installSkill(.claude)
        #expect(model.failure?.contains("a different skill is already there") == true)
        #expect(try String(contentsOf: foreign.appendingPathComponent("SKILL.md"), encoding: .utf8).contains("mine"))

        // The next action clears the message.
        model.removeCommand()
        #expect(model.failure == nil)
    }

    @Test("a build without the tool or the skill cannot offer to install them")
    func aBuildWithoutTheToolOrTheSkillCannotOfferToInstallThem() throws {
        let machine = try Machine(shipsSkill: false, shipsTool: false)
        defer { machine.cleanUp() }
        let model = AgentsModel(installer: machine.installer)
        #expect(!model.canInstallCommand)
        #expect(!model.canInstallSkill)
    }
}
