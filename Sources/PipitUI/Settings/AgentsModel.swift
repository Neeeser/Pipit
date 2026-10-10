import Foundation
import Observation
import PipitCLIKit

/// What the Agents page shows and does: the `pipit` command, and the skill in
/// each agent's folder, against the copies that ship in this app.
@MainActor
@Observable
final class AgentsModel {
    struct SkillRow: Identifiable, Equatable {
        let target: SkillTarget
        let path: String
        let state: IntegrationState

        var id: SkillTarget { target }
    }

    /// The command Settings tells a person to run for an agent Pipit does not
    /// install into itself.
    static let skillInstallCommand = "npx skills add Neeeser/Pipit"

    private(set) var commandState = IntegrationState.notInstalled
    private(set) var commandPath = ""
    private(set) var skills: [SkillRow] = []
    /// Why the last install or removal did not happen.
    private(set) var failure: String?

    @ObservationIgnored private let installer: AgentInstaller

    init(installer: AgentInstaller = AgentsModel.appInstaller()) {
        self.installer = installer
    }

    var canInstallCommand: Bool { installer.canInstallCommand }
    var canInstallSkill: Bool { installer.canInstallSkill }

    /// The installer for the running app. A build run from the package
    /// directory has no bundle around it, so nothing in it can be installed.
    static func appInstaller() -> AgentInstaller {
        AgentInstaller.bundled(
            in: Bundle.main.bundleURL.appendingPathComponent("Contents", isDirectory: true),
            home: FileManager.default.homeDirectoryForCurrentUser,
            // A Finder-launched app gets launchd's PATH, not the shell's, so the
            // page never reports on it.
            pathVariable: ""
        )
    }

    func refresh() {
        commandState = installer.commandState()
        commandPath = display(installer.commandLink)
        skills = installer.listedTargets().map {
            SkillRow(
                target: $0, path: display(installer.skillFolder(for: $0)), state: installer.skillState($0)
            )
        }
    }

    func installCommand() {
        attempt { try installer.installCommand() }
    }

    func removeCommand() {
        attempt { try installer.removeCommand() }
    }

    func installSkill(_ target: SkillTarget) {
        attempt { try installer.installSkill(target) }
    }

    func removeSkill(_ target: SkillTarget) {
        attempt { try installer.removeSkill(target) }
    }

    private func attempt(_ action: () throws -> some Any) {
        failure = nil
        do {
            _ = try action()
        } catch let error as CLIError {
            failure = error.message
        } catch {
            failure = error.localizedDescription
        }
        refresh()
    }

    /// A path with the home directory written `~`, as a person types it.
    private func display(_ url: URL) -> String {
        let home = installer.home.path
        guard url.path.hasPrefix(home + "/") else { return url.path }
        return "~" + url.path.dropFirst(home.count)
    }
}
