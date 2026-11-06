import PipitCore
import PipitServices
import SwiftUI

/// What is offered a folder, what files itself, and where any of it lands.
///
/// The reach picker is the tuning control, deliberately three named choices
/// rather than a confidence number: the number is what the choice sets, and a
/// number is not a thing anyone can judge from a settings pane.
struct FoldersSettingsPane: View {
    let model: SettingsModel
    @State private var folders: [MeetingFolder] = []
    private var runtime: PipitRuntime { model.runtime }

    var body: some View {
        Form {
            Section("Suggestions") {
                Toggle("Suggest a folder after each meeting", isOn: binding(\.suggestFolders))
                Picker(
                    "Suggest for",
                    selection: Binding(
                        get: { runtime.settings.enrichment.folderReach },
                        set: { newValue in
                            var settings = runtime.settings
                            settings.enrichment.folderReach = newValue
                            runtime.update(settings: settings)
                        }
                    )
                ) {
                    ForEach(SuggestionReach.allCases) { reach in
                        Text(reach.label).tag(reach)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(!runtime.settings.enrichment.suggestFolders)
                Toggle(
                    "Offer rules for recurring meetings",
                    isOn: binding(\.noticesRecurringMeetings)
                )
            }

            Section("Filing") {
                Toggle(
                    "File matching meetings automatically",
                    isOn: binding(\.filesMatchingMeetings)
                )
            }

            Section("Folders") {
                if folders.isEmpty {
                    Text("No folders")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(folders) { folder in
                        folderRow(folder)
                    }
                }
                HStack {
                    Spacer()
                    Button("Show in Finder") { runtime.revealArchive() }
                }
            }
        }
        .formStyle(.grouped)
        .task { folders = runtime.folders() }
    }

    private func folderRow(_ folder: MeetingFolder) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(FolderTint.color(folder.tintIndex))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).font(.body.weight(.medium))
                Text(folder.rule.isEmpty ? "No rule" : FolderRuleSummary.text(folder.rule))
                    .font(.caption)
                    .foregroundStyle(folder.rule.isEmpty ? .tertiary : .secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle(
                "",
                isOn: Binding(
                    get: { folder.filesAutomatically },
                    set: { newValue in
                        var updated = folder
                        updated.filesAutomatically = newValue
                        try? runtime.updateFolder(updated)
                        folders = runtime.folders()
                    }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(folder.rule.isEmpty || !runtime.settings.enrichment.filesMatchingMeetings)
            .help(
                folder.rule.isEmpty
                    ? "Needs a rule"
                    : "File matching meetings automatically"
            )
        }
    }

    private func binding(_ keyPath: WritableKeyPath<EnrichmentSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { runtime.settings.enrichment[keyPath: keyPath] },
            set: { newValue in
                var settings = runtime.settings
                settings.enrichment[keyPath: keyPath] = newValue
                runtime.update(settings: settings)
            }
        )
    }
}
