import PipitServices
import SwiftUI

/// Which page of Settings is showing.
///
/// A sidebar rather than a row of tab icons, matching the People and Meetings
/// windows, and readable at ten entries where a tab row is not.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case recording
    case processing
    case aiFeatures
    case browsers
    case folders
    case storage
    case permissions
    case agents
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .recording: "Recording"
        case .processing: "Processing"
        case .aiFeatures: "AI Features"
        case .browsers: "Browsers"
        case .folders: "Folders"
        case .storage: "Storage"
        case .permissions: "Permissions"
        case .agents: "Agents"
        case .diagnostics: "Diagnostics"
        }
    }

    /// The groups the sidebar shows, the way System Settings separates its
    /// panes: what Pipit does, where it works, and the tools behind it.
    static let groups: [[SettingsPane]] = [
        [.general, .recording, .processing, .aiFeatures],
        [.browsers, .folders, .storage, .permissions],
        [.agents, .diagnostics],
    ]

    /// The tile behind the pane's symbol in the sidebar.
    var tint: Color {
        switch self {
        case .general, .storage: .gray
        case .recording: .red
        case .processing: .indigo
        case .aiFeatures: .purple
        case .browsers: .blue
        case .folders: .teal
        case .permissions: .green
        case .agents: Color(white: 0.3)
        case .diagnostics: .orange
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .recording: "record.circle.fill"
        case .processing: "waveform"
        case .aiFeatures: "sparkles"
        case .browsers: "globe"
        case .folders: "folder.fill"
        case .storage: "internaldrive.fill"
        case .permissions: "hand.raised.fill"
        case .agents: "terminal.fill"
        case .diagnostics: "stethoscope"
        }
    }
}

public struct SettingsView: View {
    let model: SettingsModel

    public init(model: SettingsModel) {
        self.model = model
    }

    private var pane: SettingsPane { model.pane }

    public var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.pane }, set: { model.pane = $0 })) {
                ForEach(SettingsPane.groups, id: \.self) { group in
                    Section {
                        ForEach(group) { entry in
                            Label {
                                Text(entry.title)
                            } icon: {
                                SettingsPaneIcon(pane: entry)
                            }
                            .tag(entry)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 212, max: 240)
        } detail: {
            detail
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                // The name of the pane, as System Settings shows it.
                .toolbarTitle(pane.title)
        }
        .frame(minWidth: 740, minHeight: 520)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: GeneralSettingsPane(model: model)
        case .recording: RecordingSettingsPane(model: model)
        case .processing: ProcessingSettingsPane(model: model)
        case .aiFeatures: AIFeaturesSettingsPane(model: model)
        case .browsers: BrowsersSettingsPane(model: model)
        case .folders: FoldersSettingsPane(model: model)
        case .storage: StorageSettingsPane(model: model)
        case .permissions: PermissionsSettingsPane(model: model)
        case .agents: AgentsSettingsPane(agents: model.agents)
        case .diagnostics: DiagnosticsSettingsPane(model: model)
        }
    }
}

/// A pane's symbol in white on a rounded tile of its colour, as System
/// Settings draws its sidebar.
struct SettingsPaneIcon: View {
    let pane: SettingsPane

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(pane.tint.gradient))
    }
}
