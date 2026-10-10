import AppKit
import PipitCLIKit
import SwiftUI

/// The `pipit` command and the agent skill, which let a coding agent find and
/// read meetings.
struct AgentsSettingsPane: View {
    let agents: AgentsModel

    var body: some View {
        Form {
            Section("Command line") {
                AgentIntegrationRow(
                    symbol: "terminal", title: "pipit command", path: agents.commandPath,
                    state: agents.commandState, canInstall: agents.canInstallCommand,
                    install: { agents.installCommand() }, remove: { agents.removeCommand() }
                )
            }
            Section("Agent skill") {
                ForEach(agents.skills) { row in
                    AgentIntegrationRow(
                        symbol: row.target == .claude ? "sparkle" : "cpu", title: row.target.title,
                        path: row.path, state: row.state, canInstall: agents.canInstallSkill,
                        install: { agents.installSkill(row.target) },
                        remove: { agents.removeSkill(row.target) }
                    )
                }
                if agents.skills.isEmpty {
                    Text("No agents found").foregroundStyle(.secondary)
                }
                Text("Agents read your meetings as files and send what they read to their own model.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Other agents") {
                HStack {
                    Text(AgentsModel.skillInstallCommand)
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AgentsModel.skillInstallCommand, forType: .string)
                    }
                }
            }
            if let failure = agents.failure {
                Section { Text(failure).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .task { agents.refresh() }
        // A change made from a terminal while Settings is open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            agents.refresh()
        }
    }
}

/// One installable thing: what it is, where it goes, and what can be done to it.
private struct AgentIntegrationRow: View {
    let symbol: String
    let title: String
    let path: String
    let state: IntegrationState
    let canInstall: Bool
    let install: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            switch state {
            case .notInstalled:
                Button("Install", action: install).disabled(!canInstall)
            case .installed:
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Remove", action: remove)
            case .updateAvailable:
                Label("Update available", systemImage: "arrow.up.circle.fill").foregroundStyle(.orange)
                Button("Update", action: install).disabled(!canInstall)
                Button("Remove", action: remove)
            }
        }
    }
}
